#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <webkit/webkit.h>

static GMainLoop *loop;
static char *script;
static char *retry_uri;
static int result = 1;

static void evaluated(GObject *object, GAsyncResult *async_result, gpointer data)
{
    GError *error = NULL;
    JSCValue *value = webkit_web_view_call_async_javascript_function_finish(WEBKIT_WEB_VIEW(object), async_result, &error);
    if (error) {
        fprintf(stderr, "JavaScript failed: %s\n", error->message);
        g_error_free(error);
    } else {
        char *json = jsc_value_to_json(value, 0);
        printf("RESULT %s\n", json);
        g_free(json);
        g_object_unref(value);
        result = 0;
    }
    g_main_loop_quit(loop);
}

static void loaded(WebKitWebView *view, WebKitLoadEvent event, gpointer data)
{
    if (event == WEBKIT_LOAD_FINISHED) {
        if (retry_uri)
            return;
        if (g_str_has_prefix(webkit_web_view_get_uri(view), "https://")) {
            GTlsCertificate *certificate = NULL;
            GTlsCertificateFlags errors = 0;
            if (!webkit_web_view_get_tls_info(view, &certificate, &errors) || !certificate) {
                fprintf(stderr, "HTTPS navigation did not expose its certificate\n");
                g_main_loop_quit(loop);
                return;
            }
        }
        webkit_web_view_call_async_javascript_function(view, script, -1, NULL, NULL, NULL, NULL, evaluated, NULL);
    }
}

static gboolean failed(WebKitWebView *view, WebKitLoadEvent event, const char *uri, GError *error, gpointer data)
{
    fprintf(stderr, "Navigation failed for %s: %s\n", uri, error->message);
    g_main_loop_quit(loop);
    return TRUE;
}

static gboolean retry_navigation(gpointer data)
{
    char *uri = retry_uri;
    retry_uri = NULL;
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(data), uri);
    g_free(uri);
    return G_SOURCE_REMOVE;
}

static gboolean accept_test_certificate(WebKitWebView *view, const char *uri, GTlsCertificate *certificate, GTlsCertificateFlags errors, gpointer data)
{
    static gboolean retried = FALSE;
    if (retried || !certificate)
        return FALSE;
    retried = TRUE;
    GUri *parsed = g_uri_parse(uri, G_URI_FLAGS_NONE, NULL);
    webkit_network_session_allow_tls_certificate_for_host(webkit_web_view_get_network_session(view), certificate, g_uri_get_host(parsed));
    g_uri_unref(parsed);
    retry_uri = g_strdup(uri);
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, retry_navigation, g_object_ref(view), g_object_unref);
    return TRUE;
}

static gboolean authenticate(WebKitWebView *view, WebKitAuthenticationRequest *request, gpointer data)
{
    const char *user = g_getenv("BRIMP_TEST_AUTH_USER");
    const char *password = g_getenv("BRIMP_TEST_AUTH_PASSWORD");
    const char *expected_host = g_getenv("BRIMP_TEST_AUTH_HOST");
    if (!user || !password)
        return FALSE;
    if ((expected_host && g_strcmp0(expected_host, webkit_authentication_request_get_host(request)))
        || webkit_authentication_request_is_retry(request)) {
        fprintf(stderr, "Unexpected authentication challenge\n");
        webkit_authentication_request_cancel(request);
        return TRUE;
    }
    WebKitCredential *credential = webkit_credential_new(user, password, WEBKIT_CREDENTIAL_PERSISTENCE_FOR_SESSION);
    webkit_authentication_request_authenticate(request, credential);
    webkit_credential_free(credential);
    return TRUE;
}

static gboolean timed_out(gpointer data)
{
    fprintf(stderr, "Browser smoke test timed out\n");
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: browser-smoke URL JAVASCRIPT_FILE\n");
        return 2;
    }
    const char *expected = g_getenv("WEBKIT_EXPECTED_LIBRARY_DIR");
    Dl_info library;
    if (!expected || !dladdr((void *)webkit_web_view_load_uri, &library)
        || !g_str_has_prefix(library.dli_fname, expected)) {
        fprintf(stderr, "The smoke test did not load the expected WebKit SDK\n");
        return 2;
    }
    if (!g_file_get_contents(argv[2], &script, NULL, NULL))
        return 2;
    gtk_init();
    loop = g_main_loop_new(NULL, FALSE);
    WebKitNetworkSession *session;
    const char *storage = g_getenv("BRIMP_TEST_STORAGE_DIR");
    if (storage) {
        char *data = g_build_filename(storage, "data", NULL);
        char *cache = g_build_filename(storage, "cache", NULL);
        char *cookies = g_build_filename(storage, "cookies.sqlite", NULL);
        g_mkdir_with_parents(storage, 0700);
        session = webkit_network_session_new(data, cache);
        webkit_cookie_manager_set_persistent_storage(webkit_network_session_get_cookie_manager(session), cookies, WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
        g_free(data);
        g_free(cache);
        g_free(cookies);
    } else
        session = webkit_network_session_new_ephemeral();
    const char *proxy_uri = g_getenv("BRIMP_TEST_PROXY");
    if (proxy_uri) {
        WebKitNetworkProxySettings *proxy = webkit_network_proxy_settings_new(proxy_uri, NULL);
        webkit_network_session_set_proxy_settings(session, WEBKIT_NETWORK_PROXY_MODE_CUSTOM, proxy);
        webkit_network_proxy_settings_free(proxy);
    }
    WebKitWebContext *context = webkit_web_context_new();
    const char *runtime_root = g_getenv("WEBKIT_RUNTIME_ROOT");
    if (runtime_root)
        webkit_web_context_add_path_to_sandbox(context, runtime_root, TRUE);
    GtkWidget *view = g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context", context, "network-session", session, NULL);
    g_object_unref(context);
    GtkWidget *window = gtk_window_new();
    gtk_window_set_child(GTK_WINDOW(window), view);
    gtk_window_set_default_size(GTK_WINDOW(window), 800, 600);
    gtk_widget_set_visible(window, TRUE);
    g_signal_connect(view, "load-changed", G_CALLBACK(loaded), NULL);
    g_signal_connect(view, "load-failed", G_CALLBACK(failed), NULL);
    g_signal_connect(view, "authenticate", G_CALLBACK(authenticate), NULL);
    if (g_getenv("BRIMP_TEST_ALLOW_CERTIFICATE"))
        g_signal_connect(view, "load-failed-with-tls-errors", G_CALLBACK(accept_test_certificate), NULL);
    g_timeout_add_seconds(45, timed_out, NULL);
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(view), argv[1]);
    g_main_loop_run(loop);
    gtk_window_destroy(GTK_WINDOW(window));
    g_object_unref(session);
    g_main_loop_unref(loop);
    g_free(script);
    return result;
}
