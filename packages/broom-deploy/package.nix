{
  lib,
  python3,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "broom-deploy";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./broom_deploy.py
      ./test_broom_deploy.py
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
    install -Dm755 -- broom_deploy.py "$out/bin/broom-deploy"
    runHook postInstall
  '';

  __structuredAttrs = true;
  strictDeps = true;

  meta = {
    description = "Declarative OpenWrt deployer for broom with fw4 check and automatic rollback";
    homepage = "https://github.com/tie-infra/brim-infrastructure";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ tie ];
    platforms = lib.platforms.unix;
    mainProgram = "broom-deploy";
  };
}
