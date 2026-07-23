{
  jdk17,
  jdk21,
  jdk25,
  jre8,
  makeBinaryWrapper,
  runCommand,
}:
runCommand "java-wrappers"
  {
    __structuredAttrs = true;
    javaPackages = {
      java8 = jre8;
      java17 = jdk17;
      java21 = jdk21;
      java25 = jdk25;
    };
    nativeBuildInputs = [ makeBinaryWrapper ];
  }
  ''
    for name in "''${!javaPackages[@]}"; do
      makeBinaryWrapper \
        "''${javaPackages[$name]}/bin/java" \
        "$out/bin/$name"
    done
  ''
