#!/usr/bin/env bash
# K8s Exam MOTD — printed by iTerm2 "K8s Exam" profile on session start.

B='\033[1m'
D='\033[2m'
R='\033[0m'
GR='\033[0;32m'
CY='\033[0;36m'
YL='\033[0;33m'
BL='\033[0;34m'
MA='\033[0;35m'
BG='\033[1;32m'
BY='\033[1;33m'
BC='\033[1;36m'
BB='\033[1;34m'

cat <<EOF

${B}┌──────────────────────────────────────────────────────────────────────┐${R}
${B}│              K8s EXAM SIMULATOR  —  CKA · CKAD · CKS                │${R}
${B}└──────────────────────────────────────────────────────────────────────┘${R}

  ${B}${CY}TMUX${R}${D}  (prefix: Ctrl-a)${R}                 ${B}${CY}VIM${R}
  ${D}─────────────────────────────────────  ──────────────────────────────────${R}
  ${GR}Ctrl-a |${R}   vertical split             ${GR}F2${R}           toggle paste mode
  ${GR}Ctrl-a -${R}   horizontal split           ${GR}\k${R}           kubectl apply -f %
  ${GR}Alt+arrows${R} move between panes         ${GR}\d${R}           dry-run apply
  ${GR}Ctrl-a z${R}   zoom/unzoom pane           ${GR}\y${R}           set 2-space YAML indent
  ${GR}Ctrl-a [${R}   enter scroll/copy mode     ${GR}Esc Esc${R}      clear search highlight
  ${GR}Ctrl-a d${R}   detach session             ${GR}:set nu${R}      line numbers on
  ${GR}Ctrl-a r${R}   reload tmux config         ${GR}:set nonu${R}    line numbers off

  ${B}${CY}ALIASES${R}${D}  (active in this session)${R}
  ${D}────────────────────────────────────────────────────────────────────────${R}
  ${BY}k${R}               kubectl
  ${BY}kn <ns>${R}         set current namespace  (kubectl config set-context --current)
  ${BY}kx <ctx>${R}        switch context
  ${BY}kgp${R}             kubectl get pods
  ${BY}kga${R}             kubectl get all
  ${BY}ke <pod>${R}        kubectl exec -it <pod> -- /bin/sh

  ${BY}\$do${R}             ${D}--dry-run=client -o yaml${R}
  ${BY}\$now${R}            ${D}--force --grace-period 0${R}

  ${B}${CY}QUICK PATTERNS${R}
  ${D}────────────────────────────────────────────────────────────────────────${R}
  ${D}# Generate YAML without applying${R}
  ${CY}k run pod1 --image=nginx \$do > pod.yaml${R}
  ${CY}k create deploy d1 --image=nginx --replicas=3 \$do > deploy.yaml${R}
  ${CY}k create svc clusterip svc1 --tcp=80:80 \$do >> deploy.yaml${R}

  ${D}# Force-delete a stuck pod${R}
  ${CY}k delete pod pod1 \$now${R}

  ${D}# Exec into a pod / run a temp debug pod${R}
  ${CY}k exec -it pod1 -- /bin/sh${R}
  ${CY}k run tmp --image=busybox --restart=Never --rm -it -- sh${R}

  ${D}# Check recent events (sorted)${R}
  ${CY}k get events --sort-by='.lastTimestamp'${R}

  ${D}# Explain any field${R}
  ${CY}k explain pod.spec.containers.resources${R}
  ${CY}k explain deploy.spec.strategy --recursive${R}

  ${D}# Switch context / namespace${R}
  ${CY}kx <context-name>${R}
  ${CY}kn <namespace>${R}

  ${D}# Check what's running in a namespace${R}
  ${CY}k get all -n <ns>${R}

${D}  docs: kubernetes.io/docs   cheat: kubernetes.io/docs/reference/kubectl/cheatsheet/${R}
${B}────────────────────────────────────────────────────────────────────────────${R}

EOF
