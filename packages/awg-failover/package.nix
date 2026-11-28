{
  lib,
  python3,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "awg-failover";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./awg_failover.py
      ./test_awg_failover.py
    ];
  };

  buildInputs = [ python3 ];
  nativeCheckInputs = [ python3 ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python3 -m unittest discover -s . -v
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 -- awg_failover.py "$out/bin/awg-failover"
    runHook postInstall
  '';

  __structuredAttrs = true;
  strictDeps = true;

  meta = {
    description = "Event-driven IPv4 TSPU failover daemon for AmneziaWG with Cheburcheck and Telegram alerts";
    homepage = "https://github.com/tie-infra/brim-infrastructure";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ tie ];
    platforms = lib.platforms.linux;
    mainProgram = "awg-failover";
  };
}
