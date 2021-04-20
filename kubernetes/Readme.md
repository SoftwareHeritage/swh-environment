## Prerequisite

### Tools

These tools need to be installed:
- k3s (https://k3s.io)
- skaffold (https://skaffold.dev/docs/install/)

### Directories

```
sudo mkdir -p /srv/softwareheritage-kube/dev/{objects,storage-db,scheduler-db,kafka,web-db,prometheus,zookeeper/data,zookeeper/datalog,grafana,elasticsearch,redis,registry,idx-storage-db,vault-db,vault-cache,deposit-db,deposit-cache}
sudo chown 1000:1000 /srv/softwareheritage-kube/dev/{objects,elasticsearch,vault-cache,deposit-cache}
sudo chown -R 999:999 /srv/softwareheritage-kube/dev/*-db
sudo chown 472:0 /srv/softwareheritage-kube/dev/grafana
sudo chown nobody:nogroup /srv/softwareheritage-kube/dev/prometheus
```

### Registry

- Add the following line on your `/etc/hosts` file. It's needed to be able to push the image from docker
```
127.0.0.1 registry.default
```
- Start the registry in kubernetes
```
kubectl apply -f kubernetes/registry/00-registry.yml
```

If you are using k3s, the registry must be declared on the
`/etc/rancher/k3s/registries.yaml` to allow http calls:

```
mirrors:
  registry.default:
    endpoint:
    - "http://registry.default/v2/"
```

## Development

To access the services, they must be declared on the `/etc/hosts` file:
```
127.0.0.1 objstorage.default storage.default webapp.default scheduler.default rabbitmq.default grafana.default prometheus.default counters.default registry-ui.default idx-storage.default vault.default deposit.default
```

### Skaffold

To start the development environment using skaffold, use the following command:

```
skaffold --default-repo registry.default dev --trigger=[notify|manual]
```

It will build the images, deploy them on the local registry and start the services.
Choose the right trigger policy for your use case:
- **manual** skaffold will wait until <enter> is pressed to redeploy the changes
- **notify** will automatically rebuild and redeploy the changes when they are saved on disk. It give more reactivity, but generate some additional load

**manual** is recommended

## Basic commands

Hint: Use tabulation to ease finding out new commands

- List pods:
```
$ kubectl get pods
NAME                                   READY   STATUS    RESTARTS   AGE
registry-deployment-7595868dc8-657ps   1/1     Running   0          46m
objstorage-8587d58b68-76jbn            1/1     Running   0          12m
```

- List services:

```
$ kubectl get services objstorage
NAME         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
objstorage   ClusterIP   10.43.185.191   <none>        5003/TCP   17m
```

- check service is responding via the ingress

```
curl http://storage.default
<html>
<head><title>Software Heritage scheduler RPC server</title></head>
...
</html>%
```

- Check service is responding (bypass the ingress controller):

```
$ curl http://$(kubectl get services objstorage -o jsonpath='{.spec.clusterIP}'):5003
SWH Objstorage API server%

$ curl http://$(kubectl get services scheduler -o jsonpath='{.spec.clusterIP}'):5008
<html>
<head><title>Software Heritage scheduler RPC server</title></head>
...
</html>%
```

- Force a pod to redeploy itself

```
kubectl rollout restart deployment storage
```

- Clean up registry due to too much disk space used

```
kubectl exec -ti deployment/registry-deployment -- /bin/registry garbage-collect  -m /etc/docker/registry/config.yml
```
