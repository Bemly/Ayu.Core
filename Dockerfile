FROM busybox:musl

WORKDIR /test

# Copy everything (hush-json submodule included)
COPY . .

# Fix permissions: all .sh executable, log dirs writable
RUN find /test -name "*.sh" -exec chmod +x {} \; && \
    mkdir -p var/log var/state && \
    chmod 777 var/log var/state

EXPOSE 6160

# Production requires --add-host + volume mounts at runtime:
#   docker run -d --name Ayu \
#     --add-host host.docker.internal:host-gateway \
#     -p 6160:6160 \
#     -v /vol1/1000/Ayu:/test \
#     -v /vol1/1000/Lagrange/img:/tmp/img \
#     busybox:musl sh /test/cgi-bin/start.sh
#
# /tmp/img mount is REQUIRED — sync.sh downloads QQ CDN files there.
# Missing it = all downloads silently fail (3 retries → fallback URL mode).
#
# httpd is pid 1 → docker logs Ayu captures all stderr log output.
# To restart after deploy: docker exec Ayu killall httpd; docker start Ayu

CMD ["hush", "cgi-bin/start.sh"]
