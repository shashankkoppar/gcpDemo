# Project Title

GCP sample application deployment, accessing it via ingress and performing a cluster upgrade.

# Details
This script does following things in order:

```
Create two GCP clusters.
```
```
Git clone ruby-sinatra sample application and create Docker image.
```
```
Deploy the application to both clusters and expose it using ingress.
```
```
Perform a small load test and check horizontal pod scaling in action for both deployments.
```
```
Create a new node pool to upgrade cluster.
```
```
Cordon and drain the old nodes.
```
```
Delete the old node pool.
```
```
Test ingress endpoint after cluster upgrade!
```

## Getting Started

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes.

### Prerequisites

Please make sure you have following tools:

```
git
https://git-scm.com/downloads
```

```
jq
https://stedolan.github.io/jq/
```

```
gcloud
https://cloud.google.com/sdk/docs/quickstarts
```

### Installing

To get this running in local, please enable Kubernete Engine API in gcloud

```
https://console.cloud.google.com/apis/library/container.googleapis.com?q=kubernetes%20engine&_ga=2.238176192.-136528310.1549415913
```

And also have service account json ready!

```
https://console.cloud.google.com/apis/library/container.googleapis.com?q=kubernetes%20engine&_ga=2.238176192.-136528310.1549415913
```

Usage of Command is as follows

```
./gcpTest.sh {path_to_service_account_json}

For eg,
./gcpTest.sh /Users/shashank.koppar/Downloads/sinatra-test.json
```

## Notes

```
Make Sure you dont have clusters named sinatra-test-1 and sinatra-test-2 :D
```

```
Also external ip takes some time to come into effect. So hang on tight till it get ready!
```

```
Not using static ip for ingress since I just have an free version
```
