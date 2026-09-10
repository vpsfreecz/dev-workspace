{ lib }:
siteConfig:
let
  hasExactKeys =
    value: required: optional:
    builtins.isAttrs value
    && builtins.all (name: builtins.hasAttr name value) required
    && builtins.all (name: builtins.elem name (required ++ optional)) (builtins.attrNames value);
  validString = value: builtins.isString value && value != "";
  validEndpoint =
    value: hasExactKeys value [ "stagingPasswordPath" "stagingUrl" "tokenPath" "url" ] [ ];
  validJsonObject =
    value:
    builtins.isPath value
    && (
      let
        parsed = builtins.tryEval (
          let
            contents = builtins.fromJSON (builtins.readFile value);
          in
          builtins.deepSeq contents contents
        );
      in
      parsed.success && builtins.isAttrs parsed.value
    );
  kb = siteConfig.kb or { };
  clusters = siteConfig.clusterDefaults or { };
  valid =
    hasExactKeys siteConfig [ "clusterDefaults" "kb" ] [ ]
    && hasExactKeys kb [ "cz" "org" "stageContainerctl" "stagingUsername" ] [ ]
    && validEndpoint (kb.cz or { })
    && validEndpoint (kb.org or { })
    && builtins.all validString (
      builtins.attrValues (kb.cz or { })
      ++ builtins.attrValues (kb.org or { })
      ++ [
        (kb.stageContainerctl or null)
        (kb.stagingUsername or null)
      ]
    )
    && hasExactKeys clusters [ "vpsadmin" "vpsadminos" ] [ ]
    && builtins.all validJsonObject (builtins.attrValues clusters);
in
assert lib.assertMsg valid "vpsFree development workspace site configuration is invalid";
siteConfig
