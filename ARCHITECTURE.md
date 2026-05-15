# AKS Lab — Architecture

```mermaid
graph TB
    subgraph host["Mac Host"]
        setup["setup-lab.sh / resume-lab.sh"]
        tf["Terraform"] --> vault["HashiCorp Vault\nvault.aks-lab.local:8200"]
    end

    gh[("GitHub\nmarkpadam/Kubernetes-Homelab")]

    subgraph cluster["Minikube Cluster — aks-lab  (3 nodes, Docker driver)"]
        subgraph gitops["GitOps & Workflows"]
            flux["flux-system\nFlux Controllers"]
            argo["argocd\nargocd.aks-lab.local:8080"]
            argowf["argo\nArgo Workflows\nargo-workflows.aks-lab.local:2746"]
        end
        subgraph apps["Applications"]
            taskapp["taskapp\ntaskflow.aks-lab.local:8081\nNginx → Node.js → Postgres"]
            blobapp["blob-explorer\nblob-explorer.aks-lab.local:8082\n.NET · Helm chart"]
        end
        subgraph store["Storage & Shared Services"]
            azurite["azure-storage · Azurite\nBlob :10000 · Queue :10001 · Table :10002"]
            sql["azure-sql · Azure SQL Edge\n:1433"]
            rabbit["service-bus · RabbitMQ\nAMQP :5672 · Mgmt :15672"]
            reg["container-registry · Registry v2\n:5000"]
            mongo["cosmos-db · MongoDB 7\n:27017"]
        end
        subgraph infra["Infrastructure"]
            mon["monitoring\ngrafana.aks-lab.local:3000\nPrometheus + Grafana"]
            box["toolbox\nlocalhost:2222 · Ubuntu + SSH"]
            dns["dns-lab\nbind9 · simulated ADDS"]
            coredns["kube-system\nCoreDNS + stub zones"]
        end
    end

    setup -->|"kubectl / helm / flux"| cluster
    vault -.->|"Kubernetes auth backend"| cluster
    flux -->|"sync every 1 min"| gh
    argo -.->|"optional"| gh
    blobapp -->|"Azure.Storage.Blobs SDK"| azurite
    coredns -->|"stub zones"| dns
```

| Service | URL | Port |
| --- | --- | --- |
| TaskFlow | <http://taskflow.aks-lab.local:8081> | 8081 |
| Grafana | <http://grafana.aks-lab.local:3000> | 3000 |
| ArgoCD | <https://argocd.aks-lab.local:8080> | 8080 |
| Blob Explorer | <http://blob-explorer.aks-lab.local:8082> | 8082 |
| HashiCorp Vault | <http://vault.aks-lab.local:8200/ui> | 8200 |
| Argo Workflows | <http://argo-workflows.aks-lab.local:2746> | 2746 |
| RabbitMQ Management | <http://localhost:15672> | 15672 |
| Container Registry | `localhost:5000` | 5000 |
| Cosmos DB (MongoDB) | `localhost:27017` | 27017 |
| Azure SQL | `localhost:1433` | 1433 |
| Toolbox SSH | `ssh aks-toolbox` | 2222 |
