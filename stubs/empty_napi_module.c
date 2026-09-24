/*
 * N-API module that registers nothing.
 *
 * Four modules Slack bundles are macOS-only or Windows-only. Their x86_64
 * builds already export no callable symbol on Linux, and the JS that loads
 * them guards on process.platform. Replacing them with this keeps the file
 * present and the architecture correct.
 */

typedef struct napi_env__ *napi_env;
typedef struct napi_value__ *napi_value;

napi_value napi_register_module_v1(napi_env env, napi_value exports) {
  return exports;
}
