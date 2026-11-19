# Overview

# Use Cases

## Technology
* KNative
* Keda
* HPA in K8s 1.37
* GraalVM

## Key Points

Demonstrates the "Why" for GraalVM: If a webhook provider expects a 200 OK within 3 seconds, a traditional JIT-compiled Java application waking up from zero might cause a timeout. A Spring Boot GraalVM native image booting in 50ms instantly solves the cold-start penalty, making the narrative of the article highly compelling.



# Horizontal Pod Autoscaler

# Example Application

I will use two tools to do the setup: [Homebrew](https://brew.sh/) and [mise-en-place](https://mise.jdx.dev/). Both
tools work well on Linux, Mac, and Windows (that is Windows Subsystem for Linux, or WSL)

## Setup Kubernetes
Install `kubectl`. On Mac or Linux i would prefer HomeBrew (for example, the latest Ubuntu snap version of kubectl is 1.35, where the homebrew is 1.37)

```bash
brew install kubectl
````

Install k3d 

```bash
brew install k3d
```
or ..
```bash
mise use k3d@latest
```

Other installation  options https://k3d.io/stable/#installation

    
## Setup Java