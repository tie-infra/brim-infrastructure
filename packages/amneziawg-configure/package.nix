{
  lib,
  python3,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "amneziawg-configure";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./amneziawg_configure.py
      ./test_amneziawg_configure.py
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
    install -Dm755 -- amneziawg_configure.py "$out/bin/amneziawg-configure"
    runHook postInstall
  '';

  __structuredAttrs = true;
  strictDeps = true;

  meta = {
    description = "Structured systemd helper for configuring AmneziaWG 3.1 kernel interfaces";
    homepage = "https://amnezia.org";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ tie ];
    platforms = lib.platforms.linux;
    mainProgram = "amneziawg-configure";
  };
}
