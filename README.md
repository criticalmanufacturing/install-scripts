# install-scripts
Critical Manufacturing Installation Scripts

## Prepare single server Ubuntu 20.04 environment

```
$ curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/ubuntu/20.04/install.bash | bash
```

In case you want to pass your own Portainer admin password

```
$ curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/ubuntu/20.04/install.bash | bash -s -- -password <your password>
```
