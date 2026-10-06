{
  lib,
  devConfig,
  topology,
  seed,
  nodeRecords,
}:
let
  selection = devConfig.storageProfile or { };
  enabled = selection.enable or false;
  enrollment = selection.enrollment or true;
  sourceNodes = builtins.filter (node: node.role == "node") nodeRecords;
  storageNodes = builtins.filter (node: node.role == "storage") nodeRecords;
  allowed = [
    "enable"
    "enrollment"
    "backupFilesystem"
    "vpsBackupFilesystem"
    "nasFilesystem"
    "maxDatasets"
    "resources"
    "packageVersion"
    "namespaceBlocks"
  ];
  config = {
    version = if selection ? vpsBackupFilesystem then 2 else 1;
    inherit enrollment;
    environmentId = seed.environment.id;
    sourcePools = map (node: {
      nodeId = node.id;
      filesystem = devConfig.seed.pools.filesystem;
      role = "hypervisor";
    }) sourceNodes;
    backupPool = {
      nodeId = (builtins.head storageNodes).id;
      filesystem = selection.backupFilesystem or "tank/backup";
      role = "backup";
      maxDatasets = selection.maxDatasets or 32;
    };
    nasPool = {
      nodeId = (builtins.head storageNodes).id;
      filesystem = selection.nasFilesystem or "tank/nas";
      role = "primary";
      maxDatasets = selection.maxDatasets or 32;
    };
    resources =
      selection.resources or {
        cpu = 4;
        memory = 4096;
        swap = 2048;
        diskspace = 8192;
        ipv4 = 4;
        ipv4_private = 16;
      };
    packageVersion = selection.packageVersion or 1;
    namespaceBlocks = selection.namespaceBlocks or 8;
  }
  // lib.optionalAttrs (selection ? vpsBackupFilesystem) {
    vpsBackupPool = {
      nodeId = config.backupPool.nodeId;
      filesystem = selection.vpsBackupFilesystem;
      role = "backup";
      maxDatasets = selection.maxDatasets or 32;
    };
  };
  validRoot =
    value:
    builtins.isString value
    && builtins.match "[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+" value != null
    && builtins.all (
      part:
      !(builtins.elem part [
        "."
        ".."
      ])
    ) (lib.splitString "/" value);
  boundedPositive = maximum: value: builtins.isInt value && value > 0 && value <= maximum;
  checked =
    if topology != "storage" || builtins.length storageNodes != 1 || sourceNodes == [ ] then
      throw "Enabled storage profile requires storage topology with one storage node and regular source nodes"
    else if (devConfig.seed.pools.role or "hypervisor") != "hypervisor" then
      throw "Storage profile source pools must be hypervisor pools"
    else if !builtins.all (name: builtins.elem name allowed) (builtins.attrNames selection) then
      throw "Unknown storageProfile configuration field"
    else if
      !(validRoot config.backupPool.filesystem && validRoot config.nasPool.filesystem)
      || config.backupPool.filesystem == config.nasPool.filesystem
    then
      throw "Storage profile requires distinct valid NAS and backup roots"
    else if
      config.version == 2
      && (
        !(validRoot config.vpsBackupPool.filesystem)
        || builtins.length sourceNodes > 8
        || !builtins.all (pool: validRoot pool.filesystem) config.sourcePools
        || !builtins.all
          (
            pool:
            pool.nodeId != config.vpsBackupPool.nodeId || pool.filesystem != config.vpsBackupPool.filesystem
          )
          (
            config.sourcePools
            ++ [
              config.backupPool
              config.nasPool
            ]
          )
      )
    then
      throw "Storage profile VPS backup root must be valid and distinct from every configured same-node root"
    else if
      !(
        boundedPositive 1024 config.nasPool.maxDatasets
        && boundedPositive 32 config.namespaceBlocks
        && boundedPositive 1000000000 config.packageVersion
      )
    then
      throw "Storage profile limits must be bounded positive integers"
    else if
      builtins.attrNames config.resources != [
        "cpu"
        "diskspace"
        "ipv4"
        "ipv4_private"
        "memory"
        "swap"
      ]
      || !builtins.all (boundedPositive 1048576) (builtins.attrValues config.resources)
    then
      throw "Storage profile future-user resources are invalid"
    else
      config;
in
if !builtins.isAttrs selection || !builtins.isBool enabled || !builtins.isBool enrollment then
  throw "storageProfile.enable and enrollment must be booleans"
else if !enabled then
  {
    enable = false;
    config = null;
    preservingSeedMarker = { };
  }
else
  {
    enable = true;
    config = builtins.deepSeq checked checked;
    preservingSeedMarker.vpsadminPreservingSeed = builtins.toJSON {
      version = 1;
      existingAssignments = "preserve";
    };
  }
