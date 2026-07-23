final: prev: {
  zapret = prev.zapret.overrideAttrs (oldAttrs: {
    __structuredAttrs = true;
    strictDeps = true;
    buildInputs = oldAttrs.buildInputs or [ ] ++ [ final.systemdLibs ];
    buildFlags = [ "systemd" ]; # make target
  });
}
