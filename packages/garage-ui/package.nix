{
  lib,
  fetchFromGitHub,
  buildGoModule,
  buildNpmPackage,
  makeBinaryWrapper,
  go-swag,
  runCommand,
}:
buildGoModule (finalAttrs: {
  pname = "garage-ui";
  version = "0.14.0";

  src = fetchFromGitHub {
    owner = "Noooste";
    repo = "garage-ui";
    tag = "v${finalAttrs.version}";
    hash = "sha256-XlzNHTSHr8jJUPHmbyxy71hbjHt46fLPk8n8J0oAfLc=";
  };

  modRoot = "backend";
  subPackages = [ "." ];

  vendorHash = "sha256-Hd4HPMH9XssSsUiOEGaQ15gX3GWvpSeliJXDgxa+1Oc=";
  proxyVendor = true;

  frontend = buildNpmPackage {
    pname = "${finalAttrs.pname}-frontend";
    inherit (finalAttrs) version;
    src = "${finalAttrs.src}/frontend";

    npmDepsHash = "sha256-5WCijC0b8iXKupE/6n9CqWtD+sfK4pgi4MnOOI1XqJA=";

    installPhase = ''
      runHook preInstall
      cp -r -- dist "$out"
      runHook postInstall
    '';

    __structuredAttrs = true;
    strictDeps = true;
  };

  nativeBuildInputs = [
    go-swag
    makeBinaryWrapper
  ];

  ldflags = [
    "-s"
    "-w"
    "-X=main.version=${finalAttrs.version}"
  ];

  # Generate Swagger docs imported by internal/routes/routes.go.
  # See packages/pufferpanel/package.nix for why GOROOT is populated explicitly.
  preBuild = ''
    GOROOT=''${GOROOT-$(go env GOROOT)} swag init
  '';

  postInstall = ''
    mkdir -p -- "$out/share/garage-ui"
    cp -r -- "$frontend" "$out/share/garage-ui/frontend"
    wrapProgram "$out/bin/garage-ui" \
      --set-default GARAGE_UI_SERVER_FRONTEND_PATH "$out/share/garage-ui/frontend"
  '';

  __structuredAttrs = true;
  strictDeps = true;

  passthru.tests.help =
    runCommand "garage-ui-help-test"
      {
        nativeBuildInputs = [ finalAttrs.finalPackage ];
        garageUi = finalAttrs.finalPackage;
      }
      ''
        garage-ui -h 2>&1 | grep -q -- "-config"
        test -f "$garageUi/share/garage-ui/frontend/index.html"
        touch "$out"
      '';

  meta = {
    description = "Web administration UI for Garage S3-compatible object storage";
    homepage = "https://github.com/Noooste/garage-ui";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ tie ];
    mainProgram = "garage-ui";
  };
})
