## Prerequisite

### Directories

```
# sudo mkdir -p /srv/softwareheritage-kube/dev/{objects,storage-db,scheduler-db,kafka,web-db,prometheus,zookeeper/data,zookeeper/datalog,grafana,elasticsearch,redis,registry}
# sudo chown 1000:1000 /srv/softwareheritage-kube/dev/{objects,elasticsearch}
# sudo chown -R 999:999 /srv/softwareheritage-kube/dev/*-db
# sudo chown 472:0 /srv/softwareheritage-kube/dev/grafana
# sudo chown nobody:nogroup /srv/softwareheritage-kube/dev/prometheus
```

Must match the content of `05-storage-db.yaml`

### Registry

- Add the following line on your `/etc/hosts` file. It's needed to be able to
  push the image to it from docker
```
127.0.0.1 registry.default
```
- Start the registry in kubernetes
```
# cd kubernetes
# kubectl apply -f registry/00-registry.yml
```

## Build the base image

```
# cd docker
# docker build --no-cache -t swh/stack .

# docker tag swh/stack:latest registry.default/swh/stack:latest
# docker push registry.default/swh/stack:latest

```

## start the objstorage

- build image
```
# docker build -f Dockerfile.objstorage -t swh/objstorage --build-arg BASE=swh/stack .
# docker tag swh/objstorage:latest registry.default/swh/objstorage:latest
# docker push registry.default/swh/objstorage:latest
```

- start the service
```
# cd kubernetes

# kubectl apply -f 10-objstorage.yml
configmap/objstorage created
persistentvolume/objstorage-pv created
persistentvolumeclaim/objstorage-pvc created
deployment.apps/objstorage created
service/objstorage created
```
- test it
```
# kubectl get pods
NAME                                   READY   STATUS    RESTARTS   AGE
registry-deployment-7595868dc8-657ps   1/1     Running   0          46m
objstorage-8587d58b68-76jbn            1/1     Running   0          12m

# kubectl get services objstorage
NAME         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
objstorage   ClusterIP   10.43.185.191   <none>        5003/TCP   17m

# curl http://$(kubectl get services objstorage -o jsonpath='{.spec.clusterIP}'):5003
SWH Objstorage API server%
```

## Start the storage

- Start the db
```
# cd kubernetes

# kubectl apply -f 05-storage-db.yml
persistentvolume/storage-db-pv created
persistentvolumeclaim/storage-db-pvc created
secret/storage-db created
configmap/storage-db created
deployment.apps/storage-db created
service/storage-db created

# kubectl get pods
NAME                                   READY   STATUS    RESTARTS   AGE
registry-deployment-7595868dc8-657ps   1/1     Running   0          46m
objstorage-8587d58b68-76jbn            1/1     Running   0          15m
storage-db-64b7f8b684-48n7w            1/1     Running   0          4m52s

# kubectl get services storage-db
NAME         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
storage-db   ClusterIP   10.43.213.178   <none>        5432/TCP   8m19s
```
- Start the storage
```
# cd kubernetes

# kubectl apply -f 11-storage.yml
configmap/storage created
deployment.apps/storage created
service/storage created
```

- Test the service
```
# kubectl get pods
NAME                                   READY   STATUS    RESTARTS   AGE
registry-deployment-7595868dc8-657ps   1/1     Running   0          49m
storage-db-64b7f8b684-48n7w            1/1     Running   0          7m40s
storage-6b759fb974-w9rzj               1/1     Running   0          66s

# kubectl get services storage
NAME      TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
storage   ClusterIP   10.43.212.116   <none>        5002/TCP   2m24s

# curl http://$(kubectl get services storage -o jsonpath='{.spec.clusterIP}'):5002
<html>
<head><title>Software Heritage storage server</title></head>
<body>
<p>You have reached the
<a href="https://www.softwareheritage.org/">Software Heritage</a>
storage server.<br />
See its
<a href="https://docs.softwareheritage.org/devel/swh-storage/">documentation
and API</a> for more information</p>
</body>
</html>
```

## Start the scheduler

- Start the db

```
# cd kubernetes

# kubectl apply -f 15-scheduler-db.yml
persistentvolume/scheduler-db-pv unchanged
persistentvolumeclaim/scheduler-db-pvc created
secret/scheduler-db configured
configmap/scheduler-db unchanged
deployment.apps/scheduler-db unchanged
service/scheduler-db unchanged

# kubectl get services scheduler-db
NAME           TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
scheduler-db   ClusterIP   10.43.115.249   <none>        5433/TCP   110s
```

- Test the service

```
# kubectl apply -f 20-scheduler.yml
configmap/scheduler created
deployment.apps/scheduler created
service/scheduler created
ingress.networking.k8s.io/scheduler created

# kubectl get services scheduler
NAME        TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
scheduler   ClusterIP   10.43.218.74   <none>        5008/TCP   23s

# kubectl get pods              NAME                                  READY   STATUS    RESTARTS   AGE
registry-deployment-5f6894c5b-9wkmr   1/1     Running   0          28m
objstorage-5b87c549b6-f6jvc           1/1     Running   0          12m
storage-db-79bfbff68-mg7fr            1/1     Running   0          107s
storage-6bfcb87b6-7s7t8               1/1     Running   0          87s
scheduler-db-666c8dc8b4-qxm9d         1/1     Running   0          73s
scheduler-595f944854-hbsj4            1/1     Running   0          62s

# curl http://$(kubectl get services scheduler -o jsonpath='{.spec.clusterIP}'):5008
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

## Development

To access the services, they must be declared on the `/etc/hosts` file:
```
127.0.0.1 objstorage.default storage.default webapp.default scheduler.default rabbitmq.default grafana.default prometheus.default counters.default registry-ui
```

### Skaffold

To start the development environment using skaffold, use the following command:

```
skaffold  --default-repo registry.default dev
```

It will build the images, deploy them on the local registry and start the services.
It will monitor the projects to detect the changes and restart the containers when needed
