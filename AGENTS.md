This is a fork of WebKit, we added an automation worker in ./Tools/WebKitAutomationWorker.

The worker uses a single profile and session, for browser context, it's implemented by
using multiple workers via controller process in ../brimp
