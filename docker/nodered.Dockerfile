# Node-RED with the two palette packages and the CountOnce flows (the MQTT broker runs inside it).
FROM nodered/node-red:5.0.8
RUN npm install --no-audit --no-fund node-red-contrib-aedes@1.4.0 @flowfuse/node-red-dashboard@1.33.0
COPY --chown=node-red:node-red nodered/flows.json /data/flows.json
# Node-RED reads logins from this file, not from flows.json. It is not secret: it only names the
# environment variable that holds the password. Node-RED encrypts it on its first save.
COPY --chown=node-red:node-red docker/flows_cred.json /data/flows_cred.json
