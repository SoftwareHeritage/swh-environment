## Prerequisite

### Directories

```
sudo mkdir -p /srv/softwareheritage-kube/dev/{objects,storage-db,scheduler-db,kafka,web-db,prometheus,zookeeper/data,zookeeper/datalog,grafana,elasticsearch,redis,registry,idx-storage-db,vault-db,vault-cache}
sudo chown 1000:1000 /srv/softwareheritage-kube/dev/{objects,elasticsearch,vault-cache}
sudo chown -R 999:999 /srv/softwareheritage-kube/dev/*-db
sudo chown 472:0 /srv/softwareheritage-kube/dev/grafana
sudo chown nobody:nogroup /srv/softwareheritage-kube/dev/prometheus
```

### Registry

- Add the following line on your `/etc/hosts` file. It's needed to be able to
  push the image to it from docker
```
127.0.0.1 registry.default
```
- Start the registry in kubernetes
```
kubectl apply -f kubernetes/registry/00-registry.yml
```

If you are using k3s, the registry must be declared on the
`/etc/rancher/k3s/registries.yaml` as it's insecure:

```
mirrors:
  registry.default:
    endpoint:
    - "http://registry.default/v2/"
```

## Build the base image

```
cd docker
docker build --no-cache -t swh/stack .

docker tag swh/stack:latest registry.default/swh/stack:latest
docker push registry.default/swh/stack:latest
```

## Development

To access the services, they must be declared on the `/etc/hosts` file:
```
127.0.0.1 objstorage.default storage.default webapp.default scheduler.default rabbitmq.default grafana.default prometheus.default counters.default registry-ui idx-storage.default vault.default
```

### Skaffold

To start the development environment using skaffold, use the following command:

```
skaffold --default-repo registry.default dev
```

It will build the images, deploy them on the local registry and start the services.
It will monitor the projects to detect the changes and restart the containers when needed

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

- Check service is responding:

```
$ curl http://$(kubectl get services objstorage -o jsonpath='{.spec.clusterIP}'):5003
SWH Objstorage API server%

$ curl http://$(kubectl get services scheduler -o jsonpath='{.spec.clusterIP}'):5008
<html>
<head><title>Software Heritage scheduler RPC server</title></head>
<body>
<p>You have reached the
<a href="https://www.softwareheritage.org/">Software Heritage</a>
scheduler RPC server.<br />
See its
<a href="https://docs.softwareheritage.org/devel/swh-scheduler/">documentation
and API</a> for more information</p>
</body>
</html>%
```

- Force a pod to redeploy itself

```
kubectl delete pod storage-db-<tab>-<tab>
```

- Clean up registry due to too much disk space used

```
kubectl exec -ti $(kubectl get pods --no-headers -l app=registry | grep -i running | awk '{print $1}) -- /bin/registry garbage-collect  -m /etc/docker/registry/config.yml
```
