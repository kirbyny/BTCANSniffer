#include <inttypes.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "esp_err.h"
#include "esp_log.h"
#include "esp_nimble_hci.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs_flash.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "driver/twai.h"

#define TAG "BTCAN"

#define TWAI_RX_GPIO 20
#define TWAI_TX_GPIO 21

#define MAX_TEXT_LINE 160
#define TX_QUEUE_LEN 128
#define CMD_QUEUE_LEN 16
#define BYTE_ORDER_TRACKED_IDS 128

typedef enum {
    BITRATE_AUTO = 0,
    BITRATE_50K = 50000,
    BITRATE_100K = 100000,
    BITRATE_125K = 125000,
    BITRATE_250K = 250000,
    BITRATE_500K = 500000,
    BITRATE_800K = 800000,
    BITRATE_1000K = 1000000,
} bitrate_mode_t;

typedef enum {
    BYTE_ORDER_AUTO = 0,
    BYTE_ORDER_LE,
    BYTE_ORDER_BE,
} byte_order_mode_t;

typedef struct {
    char line[MAX_TEXT_LINE];
} ble_line_t;

typedef enum {
    CMD_SET_BITRATE,
    CMD_SET_BYTE_ORDER,
    CMD_GET_STATUS,
} command_type_t;

typedef struct {
    command_type_t type;
    int32_t value;
} command_t;

typedef struct {
    uint32_t id;
    bool in_use;
    bool has_prev;
    uint8_t prev[8];
    int32_t le_score;
    int32_t be_score;
} byte_order_track_t;

static QueueHandle_t s_tx_queue;
static QueueHandle_t s_cmd_queue;

static volatile bitrate_mode_t s_requested_bitrate_mode = BITRATE_AUTO;
static volatile byte_order_mode_t s_requested_byte_order = BYTE_ORDER_AUTO;

static volatile int s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_tx_handle;

static byte_order_track_t s_order_tracks[BYTE_ORDER_TRACKED_IDS];
static byte_order_mode_t s_detected_byte_order = BYTE_ORDER_AUTO;

static const ble_uuid16_t svc_uuid = BLE_UUID16_INIT(0xFFF0);
static const ble_uuid16_t tx_chr_uuid = BLE_UUID16_INIT(0xFFF1);
static const ble_uuid16_t rx_chr_uuid = BLE_UUID16_INIT(0xFFF2);

static void ble_advertise(void);

static bool bitrate_from_int(int32_t value, bitrate_mode_t *mode)
{
    switch (value) {
    case 0:
        *mode = BITRATE_AUTO;
        return true;
    case 50000:
        *mode = BITRATE_50K;
        return true;
    case 100000:
        *mode = BITRATE_100K;
        return true;
    case 125000:
        *mode = BITRATE_125K;
        return true;
    case 250000:
        *mode = BITRATE_250K;
        return true;
    case 500000:
        *mode = BITRATE_500K;
        return true;
    case 800000:
        *mode = BITRATE_800K;
        return true;
    case 1000000:
        *mode = BITRATE_1000K;
        return true;
    default:
        return false;
    }
}

static bool twai_timing_for_bitrate(bitrate_mode_t bitrate, twai_timing_config_t *timing)
{
    switch (bitrate) {
    case BITRATE_50K:
        *timing = TWAI_TIMING_CONFIG_50KBITS();
        return true;
    case BITRATE_100K:
        *timing = TWAI_TIMING_CONFIG_100KBITS();
        return true;
    case BITRATE_125K:
        *timing = TWAI_TIMING_CONFIG_125KBITS();
        return true;
    case BITRATE_250K:
        *timing = TWAI_TIMING_CONFIG_250KBITS();
        return true;
    case BITRATE_500K:
        *timing = TWAI_TIMING_CONFIG_500KBITS();
        return true;
    case BITRATE_800K:
        *timing = TWAI_TIMING_CONFIG_800KBITS();
        return true;
    case BITRATE_1000K:
        *timing = TWAI_TIMING_CONFIG_1MBITS();
        return true;
    default:
        return false;
    }
}

static void enqueue_line(const char *fmt, ...)
{
    if (s_tx_queue == NULL) {
        return;
    }

    ble_line_t msg;
    memset(&msg, 0, sizeof(msg));

    va_list args;
    va_start(args, fmt);
    vsnprintf(msg.line, sizeof(msg.line), fmt, args);
    va_end(args);

    size_t len = strnlen(msg.line, sizeof(msg.line));
    if (len < sizeof(msg.line) - 1) {
        msg.line[len] = '\n';
        msg.line[len + 1] = '\0';
    }

    xQueueSend(s_tx_queue, &msg, 0);
}

static void reset_byte_order_tracking(void)
{
    memset(s_order_tracks, 0, sizeof(s_order_tracks));
    s_detected_byte_order = BYTE_ORDER_AUTO;
}

static uint16_t get_u16_le(const uint8_t *bytes)
{
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint16_t get_u16_be(const uint8_t *bytes)
{
    return ((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1];
}

static void update_byte_order_guess(uint32_t can_id, const uint8_t *data, uint8_t dlc)
{
    if (s_requested_byte_order != BYTE_ORDER_AUTO || dlc < 2) {
        return;
    }

    byte_order_track_t *slot = NULL;
    for (size_t i = 0; i < BYTE_ORDER_TRACKED_IDS; i++) {
        if (s_order_tracks[i].in_use && s_order_tracks[i].id == can_id) {
            slot = &s_order_tracks[i];
            break;
        }
    }
    if (slot == NULL) {
        for (size_t i = 0; i < BYTE_ORDER_TRACKED_IDS; i++) {
            if (!s_order_tracks[i].in_use) {
                s_order_tracks[i].in_use = true;
                s_order_tracks[i].id = can_id;
                slot = &s_order_tracks[i];
                break;
            }
        }
    }
    if (slot == NULL) {
        return;
    }

    if (slot->has_prev) {
        int32_t le_diff = abs((int32_t)get_u16_le(data) - (int32_t)get_u16_le(slot->prev));
        int32_t be_diff = abs((int32_t)get_u16_be(data) - (int32_t)get_u16_be(slot->prev));

        if (le_diff < be_diff) {
            slot->le_score++;
        } else if (be_diff < le_diff) {
            slot->be_score++;
        }
    }

    memcpy(slot->prev, data, dlc);
    slot->has_prev = true;

    int32_t le_total = 0;
    int32_t be_total = 0;
    for (size_t i = 0; i < BYTE_ORDER_TRACKED_IDS; i++) {
        le_total += s_order_tracks[i].le_score;
        be_total += s_order_tracks[i].be_score;
    }

    byte_order_mode_t previous = s_detected_byte_order;
    if (le_total - be_total > 12) {
        s_detected_byte_order = BYTE_ORDER_LE;
    } else if (be_total - le_total > 12) {
        s_detected_byte_order = BYTE_ORDER_BE;
    }

    if (previous != s_detected_byte_order && s_detected_byte_order != BYTE_ORDER_AUTO) {
        enqueue_line("INFO,BYTE_ORDER,%s", s_detected_byte_order == BYTE_ORDER_LE ? "LE" : "BE");
    }
}

static int ble_gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;

    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            s_conn_handle = event->connect.conn_handle;
            enqueue_line("INFO,BLE,CONNECTED");
        } else {
            s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        }
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        enqueue_line("INFO,BLE,DISCONNECTED");
        ble_advertise();
        return 0;

    case BLE_GAP_EVENT_SUBSCRIBE:
        return 0;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        ble_advertise();
        return 0;

    default:
        return 0;
    }
}

static int chr_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                         struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;

    const ble_uuid_t *uuid = ctxt->chr->uuid;

    if (ble_uuid_cmp(uuid, &rx_chr_uuid.u) == 0) {
        if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
            char cmd[64] = {0};
            int len = OS_MBUF_PKTLEN(ctxt->om);
            if (len > (int)sizeof(cmd) - 1) {
                len = sizeof(cmd) - 1;
            }
            int rc = ble_hs_mbuf_to_flat(ctxt->om, cmd, len, NULL);
            if (rc != 0) {
                return BLE_ATT_ERR_UNLIKELY;
            }
            cmd[len] = '\0';

            command_t c = {0};
            if (strncasecmp(cmd, "SET BITRATE AUTO", 16) == 0) {
                c.type = CMD_SET_BITRATE;
                c.value = 0;
                xQueueSend(s_cmd_queue, &c, 0);
            } else if (strncasecmp(cmd, "SET BITRATE ", 12) == 0) {
                c.type = CMD_SET_BITRATE;
                c.value = atoi(cmd + 12);
                xQueueSend(s_cmd_queue, &c, 0);
            } else if (strncasecmp(cmd, "SET BYTEORDER AUTO", 18) == 0) {
                c.type = CMD_SET_BYTE_ORDER;
                c.value = BYTE_ORDER_AUTO;
                xQueueSend(s_cmd_queue, &c, 0);
            } else if (strncasecmp(cmd, "SET BYTEORDER LE", 16) == 0) {
                c.type = CMD_SET_BYTE_ORDER;
                c.value = BYTE_ORDER_LE;
                xQueueSend(s_cmd_queue, &c, 0);
            } else if (strncasecmp(cmd, "SET BYTEORDER BE", 16) == 0) {
                c.type = CMD_SET_BYTE_ORDER;
                c.value = BYTE_ORDER_BE;
                xQueueSend(s_cmd_queue, &c, 0);
            } else if (strncasecmp(cmd, "GET STATUS", 10) == 0) {
                c.type = CMD_GET_STATUS;
                xQueueSend(s_cmd_queue, &c, 0);
            } else {
                enqueue_line("ERR,BAD_CMD,%s", cmd);
            }
        }
        return 0;
    }

    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &tx_chr_uuid.u,
                .access_cb = chr_access_cb,
                .flags = BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_READ,
                .val_handle = &s_tx_handle,
            },
            {
                .uuid = &rx_chr_uuid.u,
                .access_cb = chr_access_cb,
                .flags = BLE_GATT_CHR_F_WRITE,
            },
            {0},
        },
    },
    {0},
};

static void ble_advertise(void)
{
    struct ble_gap_adv_params adv_params;
    struct ble_hs_adv_fields fields;

    memset(&fields, 0, sizeof(fields));
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;

    const char *name = ble_svc_gap_device_name();
    fields.name = (const uint8_t *)name;
    fields.name_len = strlen(name);
    fields.name_is_complete = 1;

    ble_gap_adv_set_fields(&fields);

    memset(&adv_params, 0, sizeof(adv_params));
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;

    uint8_t own_addr_type;
    if (ble_hs_id_infer_auto(0, &own_addr_type) != 0) {
        return;
    }

    ble_gap_adv_start(own_addr_type, NULL, BLE_HS_FOREVER, &adv_params, ble_gap_event, NULL);
}

static void ble_on_sync(void)
{
    ble_advertise();
}

static void ble_host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

static void ble_tx_task(void *arg)
{
    (void)arg;

    ble_line_t msg;
    for (;;) {
        if (xQueueReceive(s_tx_queue, &msg, portMAX_DELAY) != pdTRUE) {
            continue;
        }

        if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) {
            continue;
        }

        struct os_mbuf *om = ble_hs_mbuf_from_flat(msg.line, strlen(msg.line));
        if (om == NULL) {
            continue;
        }
        ble_gatts_notify_custom((uint16_t)s_conn_handle, s_tx_handle, om);
    }
}

static esp_err_t twai_start_with_bitrate(bitrate_mode_t bitrate)
{
    twai_timing_config_t timing;
    if (!twai_timing_for_bitrate(bitrate, &timing)) {
        return ESP_ERR_INVALID_ARG;
    }

    twai_general_config_t g_config = TWAI_GENERAL_CONFIG_DEFAULT(
        TWAI_TX_GPIO,
        TWAI_RX_GPIO,
        TWAI_MODE_LISTEN_ONLY);
    g_config.tx_queue_len = 0;
    g_config.rx_queue_len = 64;

    twai_filter_config_t f_config = TWAI_FILTER_CONFIG_ACCEPT_ALL();

    esp_err_t err = twai_driver_install(&g_config, &timing, &f_config);
    if (err != ESP_OK) {
        return err;
    }

    err = twai_start();
    if (err != ESP_OK) {
        twai_driver_uninstall();
    }

    return err;
}

static void twai_stop_driver(void)
{
    twai_stop();
    twai_driver_uninstall();
}

static bitrate_mode_t auto_detect_bitrate(void)
{
    const bitrate_mode_t candidates[] = {
        BITRATE_500K,
        BITRATE_250K,
        BITRATE_125K,
        BITRATE_1000K,
        BITRATE_100K,
        BITRATE_50K,
        BITRATE_800K,
    };

    size_t best_index = 0;
    int best_hits = -1;

    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        if (twai_start_with_bitrate(candidates[i]) != ESP_OK) {
            continue;
        }

        int hits = 0;
        TickType_t deadline = xTaskGetTickCount() + pdMS_TO_TICKS(350);
        while (xTaskGetTickCount() < deadline) {
            twai_message_t msg;
            if (twai_receive(&msg, pdMS_TO_TICKS(10)) == ESP_OK) {
                hits++;
            }
        }

        twai_stop_driver();

        if (hits > best_hits) {
            best_hits = hits;
            best_index = i;
        }
    }

    return candidates[best_index];
}

static void send_status_line(bitrate_mode_t active_bitrate)
{
    const char *order = "AUTO";
    byte_order_mode_t requested = s_requested_byte_order;
    if (requested == BYTE_ORDER_LE) {
        order = "LE";
    } else if (requested == BYTE_ORDER_BE) {
        order = "BE";
    } else if (s_detected_byte_order == BYTE_ORDER_LE) {
        order = "AUTO:LE";
    } else if (s_detected_byte_order == BYTE_ORDER_BE) {
        order = "AUTO:BE";
    }

    enqueue_line("CFG,BITRATE,%d,BYTEORDER,%s", (int)active_bitrate, order);
}

static void twai_rx_task(void *arg)
{
    (void)arg;

    bitrate_mode_t active_bitrate = BITRATE_500K;
    bool running = false;

    for (;;) {
        command_t cmd;
        while (xQueueReceive(s_cmd_queue, &cmd, 0) == pdTRUE) {
            if (cmd.type == CMD_SET_BITRATE) {
                bitrate_mode_t parsed;
                if (!bitrate_from_int(cmd.value, &parsed)) {
                    enqueue_line("ERR,BITRATE_UNSUPPORTED,%ld", (long)cmd.value);
                } else {
                    if (running) {
                        twai_stop_driver();
                        running = false;
                    }
                    s_requested_bitrate_mode = parsed;
                }
            } else if (cmd.type == CMD_SET_BYTE_ORDER) {
                s_requested_byte_order = (byte_order_mode_t)cmd.value;
                reset_byte_order_tracking();
                enqueue_line("INFO,BYTE_ORDER_MODE,%s",
                             s_requested_byte_order == BYTE_ORDER_AUTO
                                 ? "AUTO"
                                 : (s_requested_byte_order == BYTE_ORDER_LE ? "LE" : "BE"));
            } else if (cmd.type == CMD_GET_STATUS) {
                send_status_line(active_bitrate);
            }
        }

        if (!running) {
            bitrate_mode_t requested = s_requested_bitrate_mode;
            if (requested == BITRATE_AUTO) {
                enqueue_line("INFO,BITRATE,AUTO_DETECTING");
                active_bitrate = auto_detect_bitrate();
                enqueue_line("INFO,BITRATE,AUTO_RESULT,%d", (int)active_bitrate);
            } else {
                active_bitrate = requested;
            }

            if (twai_start_with_bitrate(active_bitrate) == ESP_OK) {
                running = true;
                reset_byte_order_tracking();
                send_status_line(active_bitrate);
            } else {
                enqueue_line("ERR,TWAI_START_FAILED,%d", (int)active_bitrate);
                vTaskDelay(pdMS_TO_TICKS(500));
            }
            continue;
        }

        twai_message_t msg;
        if (twai_receive(&msg, pdMS_TO_TICKS(50)) == ESP_OK) {
            if (!(msg.flags & TWAI_MSG_FLAG_RTR)) {
                update_byte_order_guess(msg.identifier, msg.data, msg.data_length_code);
            }

            uint32_t now_ms = (uint32_t)(xTaskGetTickCount() * portTICK_PERIOD_MS);
            if (msg.flags & TWAI_MSG_FLAG_EXTD) {
                enqueue_line("MSG,%" PRIu32 ",%08" PRIX32 ",%u,%02X,%02X,%02X,%02X,%02X,%02X,%02X,%02X",
                             now_ms,
                             msg.identifier,
                             msg.data_length_code,
                             msg.data[0], msg.data[1], msg.data[2], msg.data[3],
                             msg.data[4], msg.data[5], msg.data[6], msg.data[7]);
            } else {
                enqueue_line("MSG,%" PRIu32 ",%03" PRIX32 ",%u,%02X,%02X,%02X,%02X,%02X,%02X,%02X,%02X",
                             now_ms,
                             msg.identifier,
                             msg.data_length_code,
                             msg.data[0], msg.data[1], msg.data[2], msg.data[3],
                             msg.data[4], msg.data[5], msg.data[6], msg.data[7]);
            }
        }
    }
}

void app_main(void)
{
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    s_tx_queue = xQueueCreate(TX_QUEUE_LEN, sizeof(ble_line_t));
    s_cmd_queue = xQueueCreate(CMD_QUEUE_LEN, sizeof(command_t));

    reset_byte_order_tracking();

    ESP_ERROR_CHECK(esp_nimble_hci_and_controller_init());
    nimble_port_init();

    ble_hs_cfg.sync_cb = ble_on_sync;

    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_svc_gap_device_name_set("BTCAN-SNIFFER");

    ESP_ERROR_CHECK(ble_gatts_count_cfg(gatt_svcs));
    ESP_ERROR_CHECK(ble_gatts_add_svcs(gatt_svcs));

    nimble_port_freertos_init(ble_host_task);

    xTaskCreatePinnedToCore(ble_tx_task, "ble_tx", 4096, NULL, 5, NULL, 0);
    xTaskCreatePinnedToCore(twai_rx_task, "twai_rx", 6144, NULL, 6, NULL, 0);

    ESP_LOGI(TAG, "BTCAN sniffer started");
}
