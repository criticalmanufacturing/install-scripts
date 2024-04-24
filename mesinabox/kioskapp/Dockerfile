### Install the application dependencies in a full UBI Node docker image
FROM registry.access.redhat.com/ubi8/nodejs-14:latest as builder

# USER root
# WORKDIR /opt/app

###Copy package.json and package-lock.json
COPY package*.json ./
#COPY ./nodejs-rest-http/package*.json ./

### Install app dependencies
RUN npm install --production
### Copy the dependencies into a minimal Node.js image
FROM registry.access.redhat.com/ubi8/nodejs-14-minimal:latest 

ENV NODE_ENV=production \
    PORT=8081

### Required OpenShift Labels
LABEL name="nodetest" \
      maintainer="contact@criticalmanufacturing.com" \
      vendor="CRITICAL MANUFACTURING, S.A." \
      summary="nodetest container image" \
      description="nodetest container image"


### Install app dependencies from node modules
COPY --from=builder /opt/app-root/src/node_modules /opt/app-root/src/node_modules

### Copy project content
COPY . /opt/app-root/src

# Copy necessary scripts
COPY ./scriptAfterEnrollment/afterEnrollment.ps1 /opt/app-root
COPY ./scriptAfterEnrollment/deployAgent.ps1 /opt/app-root
COPY ./scriptAfterEnrollment/importSDK.ps1 /opt/app-root

### Add licenses to this directory
ADD  https://dev.criticalmanufacturing.io/repository/http/license.txt /licenses/license.txt

#ADD https://dev.criticalmanufacturing.io/repository/http/product/dev.criticalmanufacturing.io.repo etc/yum.repos.d/  #-> if is to add the repository
#COPY ./dev.criticalmanufacturing.io.repo /etc/yum.repos.d/  #-> if is to add the repository, with this way, we need to get the dev.criticalmanufacturing.io.repo file in source control

### Install other packages that we need/can need
USER root
RUN microdnf --nodocs install -y yum wget curl nano dotnet-runtime-8.0 curl ca-certificates gzip && \
        yum -y install https://github.com/PowerShell/PowerShell/releases/download/v7.4.1/powershell-7.4.1-1.rh.x86_64.rpm && \
        curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz && \
        tar -xzf oc.tar.gz && \
        mv oc /usr/local/bin/oc && \
        rm oc.tar.gz &&\
        yum clean all && \
        microdnf clean all && \
        rm -rf /var/cache/dnf /var/cache/yum
        #/etc/yum.repos.d/dev.criticalmanufacturing.io.repo
    
EXPOSE 8081
CMD ["npm", "start"]