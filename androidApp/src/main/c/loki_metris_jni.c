/* JNI只映射有界字节数组和句柄；密码、资源校验及窗口规则均调用共享Rust。 */
#include <jni.h>
#include <stdlib.h>
#include "loki_metris_mobile.h"

JNIEXPORT jlong JNICALL Java_com_manonloki_lokimetrisdisplay_NativeLinkBridge_create(JNIEnv *env, jobject owner, jbyteArray input) {
    (void)owner;
    if (!input) return 0;
    jsize length = (*env)->GetArrayLength(env, input);
    if (length <= 0 || length > 1024) return 0;
    jbyte *bytes = (*env)->GetByteArrayElements(env, input, NULL);
    if (!bytes) return 0;
    uint64_t handle = loki_mobile_create((const uint8_t *)bytes, (size_t)length);
    (*env)->ReleaseByteArrayElements(env, input, bytes, JNI_ABORT);
    return (jlong)handle;
}

JNIEXPORT jbyteArray JNICALL Java_com_manonloki_lokimetrisdisplay_NativeLinkBridge_invoke(JNIEnv *env, jobject owner, jlong handle, jbyteArray input) {
    (void)owner;
    if (!input) return NULL;
    jsize length = (*env)->GetArrayLength(env, input);
    if (length <= 0 || length > 128 * 1024) return NULL;
    jbyte *bytes = (*env)->GetByteArrayElements(env, input, NULL);
    if (!bytes) return NULL;
    uint8_t *output = malloc(LOKI_MOBILE_RESULT_CAPACITY);
    if (!output) { (*env)->ReleaseByteArrayElements(env, input, bytes, JNI_ABORT); return NULL; }
    size_t count = 0;
    int32_t status = loki_mobile_call((uint64_t)handle, (const uint8_t *)bytes, (size_t)length, output, LOKI_MOBILE_RESULT_CAPACITY, &count);
    (*env)->ReleaseByteArrayElements(env, input, bytes, JNI_ABORT);
    jbyteArray result = NULL;
    if (status >= 0 && count <= LOKI_MOBILE_RESULT_CAPACITY) {
        result = (*env)->NewByteArray(env, (jsize)count);
        if (result) (*env)->SetByteArrayRegion(env, result, 0, (jsize)count, (const jbyte *)output);
    }
    /* 结果可能含待保存材料，释放前尽力清除本JNI拥有的副本。 */
    volatile uint8_t *wipe = output;
    for (size_t i = 0; i < count && i < LOKI_MOBILE_RESULT_CAPACITY; ++i) wipe[i] = 0;
    free(output);
    return result;
}

JNIEXPORT void JNICALL Java_com_manonloki_lokimetrisdisplay_NativeLinkBridge_destroy(JNIEnv *env, jobject owner, jlong handle) {
    (void)env; (void)owner; loki_mobile_destroy((uint64_t)handle);
}

JNIEXPORT jboolean JNICALL Java_com_manonloki_lokimetrisdisplay_NativeLinkBridge_validateAsset(JNIEnv *env, jobject owner, jbyteArray descriptor, jbyteArray body) {
    (void)owner;
    if (!descriptor || !body) return JNI_FALSE;
    jsize a = (*env)->GetArrayLength(env, descriptor), b = (*env)->GetArrayLength(env, body);
    if (a <= 0 || a > 512 || b <= 0 || b > 32 * 1024 * 1024) return JNI_FALSE;
    jbyte *x = (*env)->GetByteArrayElements(env, descriptor, NULL);
    if (!x) return JNI_FALSE;
    jbyte *y = (*env)->GetByteArrayElements(env, body, NULL);
    if (!y) { (*env)->ReleaseByteArrayElements(env, descriptor, x, JNI_ABORT); return JNI_FALSE; }
    int32_t result = loki_mobile_asset_valid((const uint8_t *)x, (size_t)a, (const uint8_t *)y, (size_t)b);
    (*env)->ReleaseByteArrayElements(env, body, y, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, descriptor, x, JNI_ABORT);
    return result == 1 ? JNI_TRUE : JNI_FALSE;
}
