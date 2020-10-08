{ runCommand, hlint, src, lib }:

let
  # just haskell sources and the hlint config file
  src' = lib.cleanSourceWith {
   inherit src;
   filter = with lib;
    name: type: let baseName = baseNameOf (toString name); in (
      (type == "regular" && hasSuffix ".hs" baseName) ||
      (type == "regular" && hasSuffix ".yaml" baseName) ||
      (type == "directory")
    );
  };
in
runCommand "cardano-hlint-check" { buildInputs = [ hlint ]; } ''
  set +e
  # This is bad and should probably be fixed.
  projects=("cardano-db" "cardano-db-sync" "cardano-db-sync-extended")
  cd ${src'}
  hlint "''${projects[@]}"
  EXIT_CODE=$?
  if [[ $EXIT_CODE != 0 ]]
  then
    echo '====================================================================='
    echo 'Note: to ignore a particular hint (e.g. "Reduce duplication"), write'
    echo 'this in the source file:'
    echo '{-# ANN module ("HLint: ignore Reduce duplication" :: Text) #-}'
    exit $EXIT_CODE
  else
    echo $EXIT_CODE > $out
  fi
''
