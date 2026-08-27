#include <JavaScriptCore/JavaScript.h>

int main(void)
{
    JSGlobalContextRef context = JSGlobalContextCreate(NULL);
    JSStringRef source = JSStringCreateWithUTF8CString("1 + 1");
    JSValueRef exception = NULL;
    JSValueRef result = JSEvaluateScript(
        context, source, NULL, NULL, 1, &exception);
    int succeeded = result && !exception
        && JSValueToNumber(context, result, &exception) == 2;

    JSStringRelease(source);
    JSGlobalContextRelease(context);
    return succeeded ? 0 : 1;
}
