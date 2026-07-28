/// Browser-safe placeholder for native-only bridge operations.
///
/// Web builds route asynchronous work through [WebGatewayClient]. Keeping this
/// small compatibility surface prevents `dart:ffi` from entering the web
/// compilation graph while native builds continue to use the Rust dynamic
/// library.
class RustBridge {
  RustBridge._();

  static final RustBridge instance = RustBridge._();

  Never _nativeOnly(String operation) {
    throw UnsupportedError(
      '$operation is provided by the MDSLens Web Gateway in browser builds.',
    );
  }

  String parseEnv(String _) => _nativeOnly('Configuration parsing');
  String encodeEnv(String _) => _nativeOnly('TOML encoding');
  String encodeEnvWebscp(String _) => _nativeOnly('WebScope encoding');
  String writeEnv(String _, String __) =>
      _nativeOnly('Configuration writing');
  String reqLogin(String _, String __, String ___) =>
      _nativeOnly('Native login transport');
  String fetchS(String _, String __) =>
      _nativeOnly('Native latest-shot transport');
  String fetchSInfo(String _, String __, String ___) =>
      _nativeOnly('Shot metadata transport');
  String prepareUrl(String _, String __) =>
      _nativeOnly('Native SSH URL forwarding');
  String sshT(String _) => _nativeOnly('Native SSH');
  String fetchSig(String _, String __) => _nativeOnly('Native MDSip');
  String fetchSigSsh(String _, String __, String ___) =>
      _nativeOnly('Native MDSip over SSH');
  String prewarmSig(String _, String __) =>
      _nativeOnly('Native MDSip connection warming');
  bool cancelFetch(int _) => false;
  void disconnectSsh() {}

  String buildGitVersion() =>
      const String.fromEnvironment('MDSLENS_GIT_VERSION', defaultValue: 'web');

  String buildVersion() =>
      const String.fromEnvironment('MDSLENS_VERSION', defaultValue: '0.0.1');
}
