# Trigger infrastructure — generated from managedServices.*.on.* and deployment.on.*
#
# From on.* declarations across all managed services, generates:
#   - Smart defaults for triggered services (Type=oneshot, no wantedBy)
#   - A shared MQTT subscriber daemon (trigger-mqtt.service)
#   - Schedule timers with Persistent=true and jitter
#   - ifNewCommits guard via ExecCondition (systemd 253+)
#   - Concurrency group serialization via flock(2)
#   - outputCommit ExecStartPost for semantic git commits
#   - Deploy oneshot services (<name>-deploy.service)
#   - MQTT ACL auto-accumulation for trigger-mqtt user
#
# Usage:
#   managedServices.calc-benchmark = {
#     on.ci = "calc";
#     on.schedule = { calendar = "daily"; ifNewCommits = "/var/lib/src/calc"; };
#     concurrencyGroup = "heavy-jobs";
#     outputDir = "/var/lib/src/hq/doc/compiled/calc";
#     outputCommit = "compiled: calc benchmarks";
#     service.script = "cd /var/lib/src/calc && ./scripts/bench-history.sh 50";
#   };
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.managedServices;

  # ── Normalization helpers ─────────────────────────────────────
  normalizeCi = ci: let
    parsed =
      if builtins.isString ci
      then {
        repo = ci;
        branch = "main";
      }
      else ci;
  in {
    topic = "git/ci/${parsed.repo}";
    filter = {
      status = "PASS";
      inherit (parsed) branch;
    };
  };

  normalizeSchedule = sched:
    if builtins.isString sched
    then {
      calendar = sched;
      ifNewCommits = null;
    }
    else sched;

  normalizeOutputCommit = svc:
    if svc.outputCommit == null
    then null
    else if builtins.isString svc.outputCommit
    then {
      message = svc.outputCommit;
      repo = null;
      paths = [];
    }
    else svc.outputCommit;

  # ── Service classification ────────────────────────────────────
  hasJobTrigger = svc:
    svc.on.ci != null || svc.on.schedule != null || svc.on.mqtt != null;

  hasDeployTrigger = svc:
    svc.deployment.on.ci
    != null
    || svc.deployment.on.schedule != null
    || svc.deployment.on.mqtt != null;

  allTriggered = lib.filterAttrs (_: svc: svc.enable && (hasJobTrigger svc || hasDeployTrigger svc)) cfg;
  jobTriggered = lib.filterAttrs (_: svc: svc.enable && hasJobTrigger svc) cfg;
  deployTriggered = lib.filterAttrs (_: svc: svc.enable && hasDeployTrigger svc) cfg;

  autoStateDir = name: svc:
    if svc.stateDir != null
    then svc.stateDir
    else "/var/lib/jobs/${name}";

  # ── MQTT trigger collection ───────────────────────────────────
  collectMqttForSvc = name: svc: let
    jobMqtt =
      lib.optional (svc.on.ci != null) ((normalizeCi svc.on.ci) // {unit = svc.serviceName;})
      ++ lib.optional (svc.on.mqtt != null) (svc.on.mqtt // {unit = svc.serviceName;});
    deployMqtt =
      lib.optional (svc.deployment.on.ci != null) ((normalizeCi svc.deployment.on.ci) // {unit = "${name}-deploy";})
      ++ lib.optional (svc.deployment.on.mqtt != null) (svc.deployment.on.mqtt // {unit = "${name}-deploy";});
  in
    jobMqtt ++ deployMqtt;

  allMqttTriggers = lib.concatLists (lib.mapAttrsToList collectMqttForSvc allTriggered);
  uniqueTopics = lib.unique (map (t: t.topic) allMqttTriggers);

  # ── Schedule trigger collection ───────────────────────────────
  allScheduleTriggers = lib.concatLists (lib.mapAttrsToList (
      name: svc:
        lib.optional (svc.on.schedule != null) {
          inherit name;
          unit = svc.serviceName;
          schedule = normalizeSchedule svc.on.schedule;
        }
        ++ lib.optional (svc.deployment.on.schedule != null) {
          name = "${name}-deploy";
          unit = "${name}-deploy";
          schedule = {
            calendar = svc.deployment.on.schedule;
            ifNewCommits = null;
          };
        }
    )
    allTriggered);

  # ── JQ filter generation ──────────────────────────────────────
  filterToJqExpr = filter: let
    conditions = lib.mapAttrsToList (k: v: ".${k} == \"${v}\"") filter;
  in
    if conditions == []
    then "true"
    else lib.concatStringsSep " and " conditions;

  # ── Script generators ─────────────────────────────────────────
  mqttDispatchScript = pkgs.writeShellScript "trigger-mqtt-dispatch" ''
    set -uo pipefail
    while IFS= read -r line; do
      topic="$(printf '%s' "$line" | ${pkgs.jq}/bin/jq -r '.topic')"
      payload="$(printf '%s' "$line" | ${pkgs.jq}/bin/jq '.payload')"
      ${lib.concatMapStrings (t: ''
        if [ "$topic" = "${t.topic}" ]; then
          if printf '%s' "$payload" | ${pkgs.jq}/bin/jq -e '${filterToJqExpr t.filter}' >/dev/null 2>&1; then
            if ! /run/current-system/sw/bin/systemctl is-active --quiet ${t.unit}.service 2>/dev/null; then
              /run/current-system/sw/bin/systemctl start ${t.unit}.service &
              echo "$(date -Iseconds) triggered ${t.unit} via ${t.topic}" >&2
            else
              echo "$(date -Iseconds) skipped ${t.unit} (already active)" >&2
            fi
          fi
        fi
      '')
      allMqttTriggers}
    done
  '';

  mkIfNewCommitsCondition = name: svc: repoPath:
    pkgs.writeShellScript "trigger-guard-${name}" ''
      state_dir="${autoStateDir name svc}"
      last_sha="$(cat "$state_dir/.last-trigger-sha" 2>/dev/null || echo "")"
      current_sha="$(${pkgs.git}/bin/git -C ${lib.escapeShellArg repoPath} rev-parse HEAD 2>/dev/null || echo unknown)"
      [ "$last_sha" != "$current_sha" ]
    '';

  mkShaUpdateScript = name: svc: repoPath:
    pkgs.writeShellScript "trigger-sha-update-${name}" ''
      state_dir="${autoStateDir name svc}"
      ${pkgs.git}/bin/git -C ${lib.escapeShellArg repoPath} rev-parse HEAD > "$state_dir/.last-trigger-sha"
    '';

  mkOutputCommitScript = name: svc: let
    commitCfg = normalizeOutputCommit svc;
    addPaths =
      if commitCfg.paths != []
      then lib.concatMapStringsSep " " lib.escapeShellArg commitCfg.paths
      else lib.escapeShellArg svc.outputDir;
  in
    pkgs.writeShellScript "trigger-commit-${name}" ''
      set -euo pipefail
      repo=${
        if commitCfg.repo != null
        then lib.escapeShellArg commitCfg.repo
        else "\"$(${pkgs.git}/bin/git -C ${lib.escapeShellArg svc.outputDir} rev-parse --show-toplevel)\""
      }
      ${pkgs.git}/bin/git -C "$repo" add ${addPaths}
      ${pkgs.git}/bin/git -C "$repo" diff --cached --quiet || \
        ${pkgs.git}/bin/git -C "$repo" commit -m ${lib.escapeShellArg commitCfg.message}
    '';

  # Build a flake ref that uses the path: fetcher instead of git+file:
  # This avoids libgit2's safe.directory ownership check when the deploy
  # user differs from the repo owner (src-sync).
  deployBuildRef = svc: let
    expr = svc.deployment.buildExpr;
  in
    if lib.hasPrefix ".#" expr
    then "path:${svc.deployment.source}#${lib.removePrefix ".#" expr}"
    else if lib.hasPrefix "./" expr
    then "path:${svc.deployment.source}/${lib.removePrefix "./" (builtins.head (lib.splitString "#" expr))}#${builtins.elemAt (lib.splitString "#" expr) 1}"
    else expr;

  mkDeployScript = name: svc:
    pkgs.writeShellScript "trigger-deploy-${name}" ''
      set -euo pipefail
      result=$(/run/current-system/sw/bin/nix build ${lib.escapeShellArg (deployBuildRef svc)} \
        --no-link --print-out-paths | tail -1)
      # Atomic symlink swap (same mechanism as auto-deploy)
      ln -sfn "$result" ${lib.escapeShellArg "${svc.deployment.slotPath}.tmp"}
      mv -fT ${lib.escapeShellArg "${svc.deployment.slotPath}.tmp"} ${lib.escapeShellArg svc.deployment.slotPath}
      /run/wrappers/bin/sudo /run/current-system/sw/bin/systemctl restart ${svc.deployment.slot.restartUnit}
    '';
in {
  # Fixed-structure config — dynamic computation happens inside each option path,
  # not in the config structure itself. This avoids infinite recursion from
  # config.managedServices being forced during module evaluation.
  config = {
    # ── systemd.services: smart defaults + MQTT daemon + schedule launchers +
    #    ifNewCommits + concurrency + outputCommit + deploy oneshots ──────
    systemd.services = lib.mkMerge (
      # Smart defaults for triggered services (oneshot, no boot start)
      (lib.mapAttrsToList (
          name: svc:
            lib.mkIf (hasJobTrigger svc && svc.service != null) {
              ${svc.serviceName} = {
                serviceConfig =
                  lib.mapAttrs (_: lib.mkOverride 900) {
                    Type = "oneshot";
                    Restart = "no";
                  }
                  // lib.optionalAttrs (svc.stateDir == null) {
                    ReadWritePaths = lib.mkOverride 900 [(autoStateDir name svc)];
                  };
                wantedBy = lib.mkForce [];
              };
            }
        )
        jobTriggered)
      # Shared MQTT subscriber daemon
      ++ [
        (lib.mkIf (allMqttTriggers != []) {
          trigger-mqtt = {
            description = "MQTT event trigger dispatcher";
            wantedBy = ["multi-user.target"];
            after = ["network.target" "mosquitto.service"];
            serviceConfig = {
              Type = "simple";
              Restart = "always";
              RestartSec = 10;
              ExecStart = let
                host =
                  if config ? mqtt && config.mqtt ? host
                  then config.mqtt.host
                  else "localhost";
                port =
                  if config ? mqtt && config.mqtt ? port
                  then toString config.mqtt.port
                  else "1883";
                hasPassword =
                  config ? mqtt
                  && config.mqtt ? users
                  && config.mqtt.users ? trigger-mqtt
                  && config.mqtt.users.trigger-mqtt ? passwordFile
                  && config.mqtt.users.trigger-mqtt.passwordFile != null;
                passwordFile =
                  if hasPassword
                  then config.mqtt.users.trigger-mqtt.passwordFile
                  else null;
              in
                pkgs.writeShellScript "trigger-mqtt-run" ''
                  ${lib.optionalString (passwordFile != null) ''
                    MQTT_PASS=$(cat ${lib.escapeShellArg passwordFile})
                  ''}
                  exec ${pkgs.mosquitto}/bin/mosquitto_sub \
                    -h ${host} -p ${port} \
                    -u trigger-mqtt \
                    ${lib.optionalString (passwordFile != null) ''-P "$MQTT_PASS" \''}
                    ${lib.concatMapStrings (topic: "-t '${topic}' ") uniqueTopics} \
                    -F '{"topic":"%t","payload":%p}' \
                  | ${mqttDispatchScript}
                '';
            };
          };
        })
      ]
      # Schedule launcher services
      ++ (map (t: {
          "trigger-${t.name}" = {
            description = "Launch ${t.unit} on schedule";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "/run/current-system/sw/bin/systemctl start ${t.unit}.service";
            };
          };
        })
        allScheduleTriggers)
      # ifNewCommits guard (ExecCondition)
      ++ (lib.mapAttrsToList (name: svc: let
        sched = normalizeSchedule svc.on.schedule;
      in
        lib.mkIf (svc.on.schedule != null && sched.ifNewCommits != null && svc.service != null) {
          ${svc.serviceName}.serviceConfig.ExecCondition =
            mkIfNewCommitsCondition name svc sched.ifNewCommits;
        })
      jobTriggered)
      # ifNewCommits SHA update (ExecStartPost)
      ++ (lib.mapAttrsToList (name: svc: let
        sched = normalizeSchedule svc.on.schedule;
      in
        lib.mkIf (svc.on.schedule != null && sched.ifNewCommits != null && svc.service != null) {
          ${svc.serviceName}.serviceConfig.ExecStartPost = [(mkShaUpdateScript name svc sched.ifNewCommits)];
        })
      jobTriggered)
      # Concurrency group flocks
      ++ (lib.mapAttrsToList (_: svc:
        lib.mkIf (svc.concurrencyGroup != null && svc.service != null) {
          ${svc.serviceName}.serviceConfig.ExecStartPre = ["${pkgs.util-linux}/bin/flock /run/trigger-locks/${svc.concurrencyGroup}.lock true"];
        })
      allTriggered)
      # outputCommit (ExecStartPost)
      ++ (lib.mapAttrsToList (name: svc:
        lib.mkIf (svc.outputCommit != null && svc.service != null) {
          ${svc.serviceName}.serviceConfig.ExecStartPost = [(mkOutputCommitScript name svc)];
        })
      allTriggered)
      # Deploy oneshot services
      ++ (lib.mapAttrsToList (name: svc: {
          "${name}-deploy" = {
            description = "Deploy ${name} from local source";
            wantedBy = [];
            serviceConfig = {
              Type = "oneshot";
              Restart = "no";
              User =
                if config ? slots && config.slots ? deployUser
                then config.slots.deployUser
                else "root";
              ExecStart = mkDeployScript name svc;
              ExecStartPre =
                if svc.concurrencyGroup != null
                then ["${pkgs.util-linux}/bin/flock /run/trigger-locks/${svc.concurrencyGroup}.lock true"]
                else ["${pkgs.util-linux}/bin/flock /run/trigger-locks/deploys.lock true"];
            };
          };
        })
        deployTriggered)
    );

    # ── systemd.timers: schedule triggers ───────────────────────
    systemd.timers = lib.mkMerge (map (t: {
        "trigger-${t.name}" = {
          description = "Schedule trigger for ${t.name}";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = t.schedule.calendar;
            Persistent = true;
            RandomizedDelaySec = "30s";
          };
        };
      })
      allScheduleTriggers);

    # ── systemd.tmpfiles.rules: lock dir + auto stateDir for triggered services ──
    systemd.tmpfiles.rules =
      lib.optional (allTriggered != {}) "d /run/trigger-locks 0777 root root -"
      ++ lib.concatLists (lib.mapAttrsToList (
          name: svc:
            lib.optional (hasJobTrigger svc && svc.stateDir == null)
            "d ${autoStateDir name svc} 0750 ${
              if svc.user != null
              then svc.user
              else "root"
            } ${
              if svc.group != null
              then svc.group
              else "root"
            } -"
        )
        jobTriggered);

    # ── MQTT ACL for trigger-mqtt user ──────────────────────────
    mqtt.users = lib.mkIf (allMqttTriggers != [] && config ? mqtt && config.mqtt ? users) {
      trigger-mqtt.acl = map (topic: "read ${topic}") uniqueTopics;
    };
  };
}
