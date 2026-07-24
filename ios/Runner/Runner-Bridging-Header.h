#import "GeneratedPluginRegistrant.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

char* mds_parse_environment(const char* path);
uint32_t mds_bridge_abi_version(void);
char* mds_encode_environment(const char* config_json);
char* mds_write_environment(const char* config_json, const char* path);
char* mds_request_login(const char* api_url, const char* user, const char* pass);
char* mds_fetch_shot(const char* api_url, const char* token);
char* mds_fetch_shot_info(const char* api_url, const char* token, const char* shot);
char* mds_ssh_test(const char* settings_json);
char* mds_fetch_signals(const char* config_json, const char* mode_json);
char* mds_fetch_signals_ssh(const char* config_json, const char* mode_json, const char* ssh_settings_json);
char* mds_prepare_url(const char* url, const char* settings_json);
void mds_free_string(char* ptr);

#ifdef __cplusplus
}
#endif
