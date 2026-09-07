#pragma once

#ifdef __cplusplus
extern "C" {
#endif

const char *photo_wagon_index_json(const char *root_path);
void photo_wagon_index_free(const char *json_ptr);

const char *photo_wagon_face_scan_and_list_json(const char *root_path);
const char *photo_wagon_face_list_json(void);
bool photo_wagon_face_set_name(long face_id, const char *name);
const char *photo_wagon_people_scan_and_list_json(const char *root_path);
const char *photo_wagon_people_list_json(void);
bool photo_wagon_fingerprint_set_name(long fingerprint_id, const char *name);
const char *photo_wagon_face_db_status_json(void);
const char *photo_wagon_face_state_json(void);

typedef void (*photo_wagon_face_event_callback)(void *user_data, long unknown_people_count, bool scan_in_progress);
void photo_wagon_face_set_event_callback(photo_wagon_face_event_callback callback, void *user_data);

#ifdef __cplusplus
}
#endif
