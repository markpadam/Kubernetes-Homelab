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
            rabbit["service-bus · Service Bus Emulator\nAMQP :5672 · Health :5300"]
            reg["container-registry · Registry v2\n:5000"]
            mongo["cosmos-db · Cosmos DB Emulator\nNoSQL :8081 · Explorer :1234"]
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
| Service Bus (AMQP) | `localhost:5672` | 5672 |
| Container Registry | `localhost:5000` | 5000 |
| Cosmos DB (NoSQL) | `http://localhost:8081` · Explorer: `http://localhost:1234` | 8081 / 1234 |
| Azure SQL | `localhost:1433` | 1433 |
| Toolbox SSH | `ssh aks-toolbox` | 2222 |
