#include "nodeapp_rpc_router.h"

#include <stddef.h>
#include <string.h>

typedef struct {
    const char   *api_name;
    msg_func_t    func;
} msg_entry_t;

json_t *C_kernel__on_port_occupied_error(json_t *message);

json_t *C_kernel__log(json_t *message) {
    const char *text = json_string_value(json_object_get(message, "text"));
    const char *level = json_string_value(json_object_get(message, "level"));
    fprintf(stderr, "[Node %s] %s\n", level, text);
    return NULL;
}

msg_entry_t entries[] = {
    { "kernel.log", C_kernel__log },
    { "kernel.on-port-occupied-error", C_kernel__on_port_occupied_error },
    { NULL, NULL }
};

msg_func_t find_msg_handler(const char *api_name) {
    for (msg_entry_t *entry = entries; entry->api_name; entry++) {
        if (0 == strcmp(api_name, entry->api_name))
            return entry->func;
    }
    return NULL;
}
