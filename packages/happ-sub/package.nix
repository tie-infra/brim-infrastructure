{
  lib,
  python3,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "happ-sub";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./happ_sub.py
      ./test_happ_sub.py
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
    install -Dm755 -- happ_sub.py "$out/bin/happ-sub"
    runHook postInstall
  '';

  __structuredAttrs = true;
  strictDeps = true;

  meta = {
    description = "Minimal Marzban-compatible Happ VPN subscription server";
    homepage = "https://github.com/tie-infra/brim-infrastructure";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ tie ];
    platforms = lib.platforms.linux;
    mainProgram = "happ-sub";
  };
}
