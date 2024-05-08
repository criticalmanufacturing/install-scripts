# Install the application dependencies in a full UBI Node docker image
FROM registry.access.redhat.com/ubi9/nodejs-20:latest as builder

# Configure workdir
USER root
WORKDIR /opt/app-root/src

# Copy package and package-lock
COPY package*.json ./

# Install app dependencies
RUN npm ci --only=production

# Use a minimal nodejs image for the final target
FROM registry.access.redhat.com/ubi9/nodejs-20-minimal:latest 

# Configure workdir
USER root
EXPOSE 8081
WORKDIR /opt/app-root/src

# Required Red Hat certification labels
LABEL name="cmos" \
      maintainer="contact@criticalmanufacturing.com" \
      vendor="CRITICAL MANUFACTURING, S.A." \
      summary="Critical Manufacuring OS" \
      description="An application to setup the system for App Platform and Apps"

# Node production and web server port
ENV NODE_ENV=production \
    PORT=8081

# Add licenses to this directory
ADD  https://dev.criticalmanufacturing.io/repository/http/license.txt /licenses/license.txt

### Install other packages that we need/can need
### TODO: do we need to install: dotnet, oc, wget, gzip
RUN microdnf --nodocs install -y yum nano ca-certificates && \
    yum -y install https://github.com/PowerShell/PowerShell/releases/download/v7.4.1/powershell-7.4.1-1.rh.x86_64.rpm && \
    npm install @criticalmanufacturing/portal@latest --no-save \
    # curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz && \
    # tar -xzf oc.tar.gz && \
    # mv oc /usr/local/bin/oc && \
    # rm oc.tar.gz &&\
    yum clean all && \
    microdnf clean all && \
    rm -rf /var/cache/dnf /var/cache/yum

# Copy necessary scripts
COPY ./scriptAfterEnrollment/afterEnrollment.ps1 /opt/app-root
COPY ./scriptAfterEnrollment/deployAgent.ps1 /opt/app-root
COPY ./scriptAfterEnrollment/importSDK.ps1 /opt/app-root

# Install app dependencies from node modules
COPY --from=builder /opt/app-root/src/node_modules /opt/app-root/src/node_modules

# Copy app content
COPY . /opt/app-root/src

CMD ["npm", "start"]