FROM busybox:musl

WORKDIR /test

# Copy everything (hush-json submodule included)
COPY . .

# Fix permissions: all .sh executable, log dirs writable
RUN find /test -name "*.sh" -exec chmod +x {} \; && \
    mkdir -p var/log var/state && \
    chmod 777 var/log var/state

EXPOSE 6160

# Production requires --add-host host.docker.internal:host-gateway at runtime:
#   docker run -d --name Ayu \
#     --add-host host.docker.internal:host-gateway \
#     -p 6160:6160 \
#     -v /vol1/1000/Ayu:/test \
#     -v /vol1/1000/Lagrange/img:/tmp/img \
#     busybox:musl sh -c "while true; do sleep 3600; done"
#
# Then start httpd:
#   docker exec Ayu sh -c "cd /test && hush cgi-bin/start.sh"

CMD ["hush", "cgi-bin/start.sh"]
