# Introduction

The `create-dr-clusters.sh` script is a utility tools for setting up a complete DR setup barring the installation of submariner addons
It will create two clusters and deploy the neccessary dependencies to them.
The following steps are performed:

1. Creates Hub and Spoke clusters
2. Installs ODF on both Clusters 
3. Label nodes and create StorageSystem
4. Deploy ACM on Hub cluster and create a multiclusterhub
5. Add the created spoke cluster to Hub


# Using the Script 

1. Create a file pull-secret.txt and add your pull secret credentials to it
2. Run the following command to create the hub cluster, spoke cluster and add the spoke to the hub
```
./create-dr-clusters.sh -am 
```
3. Once done with the usage. You can delete the hub and spoke clusters using the following command
```
./create-dr-clusters.sh -c 
```
