minikube start --driver=docker

flux bootstrap github \
    --owner=markpadam \
    --repository=Kubernetes-Homelab \
    --branch=main \
    --path=clusters/minikube \
    --personal