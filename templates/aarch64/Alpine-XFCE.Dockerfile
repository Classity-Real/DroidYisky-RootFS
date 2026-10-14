# Dockerfile (Alpine Linux XFCE)
# Stage 1: Build and customize the rootfs for development (XFCE - Alpine Linux)
ARG TARGETPLATFORM
FROM alpine:3.23 AS customizer

# Install key packages
RUN apk update && apk upgrade && \
    apk add \
    # Core utilities
    bash \
    coreutils \
    file \
    findutils \
    grep \
    sed \
    gawk \
    curl \
    wget \
    ca-certificates \
    tzdata \
    bash-completion \
    shadow \
    sudo \
    # System tools
    htop \
    vim \
    nano \
    git \
    openssh \
    net-tools \
    iptables-legacy \
    iputils \
    iproute2 \
    procps \
    fastfetch \
    kmod \
    # Development tools
    build-base \
    cmake \
    clang \
    llvm \
    valgrind \
    strace \
    ltrace \
    # Python
    python3 \
    py3-pip \
    # Docker
    docker \
    # DHCP client + openrc
    dhcpcd \
    openrc \
    busybox-extras \
    # Audio
    pulseaudio \
    pulseaudio-utils \
    pavucontrol \
    # X11 + XFCE Desktop
    xorg-server \
    xinit \
    xfce4 \
    xfce4-terminal \
    xfce4-session \
    xfce4-screensaver \
    xfce4-taskmanager \
    xfce4-screenshooter \
    xfce4-clipman-plugin \
    thunar \
    thunar-volman \
    thunar-archive-plugin \
    mousepad \
    ristretto \
    galculator \
    dbus \
    dbus-x11 \
    at-spi2-core \
    tumbler \
    adwaita-icon-theme \
    hicolor-icon-theme \
    papirus-icon-theme \
    font-dejavu \
    font-liberation \
    font-noto \
    xdg-user-dirs \
    xclip \
    xsel \
    zenity \
    libnotify \
    polkit \
    && rm -rf /var/cache/apk/*

# Copy custom scripts
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh
COPY scripts/xfce-start /usr/local/bin/xfce-start
COPY scripts/xfwm4.xml /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml
COPY scripts/xfwm4.xml /root/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml

# Make scripts executable
RUN chmod +x /etc/profile.d/ds-aliases.sh /usr/local/bin/xfce-start

# Configure environment
RUN mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Apply Android compatibility fixes + OpenRC XFCE autostart
RUN <<EOF_RUN
# --- 1. General Fixes ---
# Android network group setup (required for socket access on Android kernels)
grep -q '^aid_inet:' /etc/group    || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

# Root permissions for Android hardware access
usermod -a -G aid_inet,aid_net_raw,input,video,tty root || true

# Configure legacy iptables (MANDATORY for Android compatibility)
ln -sf /usr/sbin/iptables-legacy /usr/sbin/iptables && \
ln -sf /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables && \
ln -sf /usr/sbin/arptables-legacy /usr/sbin/arptables && \
ln -sf /usr/sbin/ebtables-legacy /usr/sbin/ebtables

# Tell OpenRC it's in an LXC-style container.
sed -i 's/^#\?rc_sys=.*/rc_sys="lxc"/' /etc/rc.conf

# Remove "dev" dependency from machine-id init script to prevent boot warnings
if [ -f /etc/init.d/machine-id ]; then
    sed -i 's/need root dev/need root/' /etc/init.d/machine-id
fi

# Fix inittab:
# 1. Remove useless tty1-6 (no VTs in a container)
# 2. Add console getty for the Droidspaces foreground console
# 3. Add console to securetty so root login is allowed
sed -i '/^tty[1-6]::/d' /etc/inittab
grep -q 'console::respawn' /etc/inittab || \
    echo 'console::respawn:/sbin/getty 38400 console' >> /etc/inittab
grep -q '^console$' /etc/securetty || echo 'console' >> /etc/securetty

# Wire up services to the default runlevel
mkdir -p /etc/runlevels/default
ln -sf /etc/init.d/dhcpcd /etc/runlevels/default/dhcpcd
ln -sf /etc/init.d/sshd /etc/runlevels/default/sshd
ln -sf /etc/init.d/containerd /etc/runlevels/default/containerd
ln -sf /etc/init.d/docker /etc/runlevels/default/docker
ln -sf /etc/init.d/dbus /etc/runlevels/default/dbus

# Replace dhcpcd init script to only start in NAT network mode
cat > /etc/init.d/dhcpcd << 'INITEOF'
#!/sbin/openrc-run

description="DHCP Client Daemon"

command="/sbin/dhcpcd"
command_args="-q -B ${command_args:-}"
command_background="true"
pidfile="/run/dhcpcd/pid"

depend() {
	provide net
	need localmount
	use logger network
	after bootmisc modules
	before dns
}

start_pre() {
	# Only start in NAT mode - prevents cellular network breakage in host network mode
	if ! grep -qE 'net_mode=(nat|gateway)' /run/droidspaces/container.config 2>/dev/null; then
		einfo "Skipping dhcpcd: not in NAT network mode"
		return 1
	fi
	checkpath -d /run/dhcpcd
}
INITEOF
chmod +x /etc/init.d/dhcpcd

# Additionally whitelist only container veth interfaces (eth*) in dhcpcd.conf
if [ -f /etc/dhcpcd.conf ]; then
    echo "allowinterfaces eth*" >> /etc/dhcpcd.conf
fi

# XFCE autostart service (OpenRC + supervise-daemon)
cat > /etc/init.d/xfce-autostart << 'EOT'
#!/sbin/openrc-run

description="XFCE desktop on Termux:X11 (Droidspaces)"
pidfile="/run/xfce-autostart.pid"

depend() {
    need dbus
    after localmount
}

x11_enabled() {
    grep -qs 'enable_termux_x11=1' /run/droidspaces/container.config
}

start() {
    if ! x11_enabled; then
        einfo "Termux:X11 not enabled for this container; desktop not started"
        return 0
    fi
    ebegin "Starting XFCE desktop"
    supervise-daemon xfce-autostart --start \
        --pidfile "$pidfile" --respawn-delay 3 \
        /usr/local/bin/xfce-start
    eend $?
}

stop() {
    x11_enabled || return 0
    ebegin "Stopping XFCE desktop"
    supervise-daemon xfce-autostart --stop --pidfile "$pidfile"
    eend $?
}
EOT
chmod 0755 /etc/init.d/xfce-autostart
ln -sf /etc/init.d/xfce-autostart /etc/runlevels/default/xfce-autostart

# xfwm4 vblank_mode=off for Turnip/Qualcomm GPU compatibility
if [ -f /usr/share/xfwm4/defaults ]; then
    if grep -q '^vblank_mode=' /usr/share/xfwm4/defaults; then
        sed -i 's/^vblank_mode=.*/vblank_mode=off/' /usr/share/xfwm4/defaults
    else
        echo 'vblank_mode=off' >> /usr/share/xfwm4/defaults
    fi
fi

# Update icon/font caches
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/Adwaita 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/Papirus 2>/dev/null || true
fc-cache -fv 2>/dev/null || true

# Mark fixes as completed
echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# Final cleanup
RUN rm -rf /var/cache/apk/*

# Stage 2: Export to scratch for extraction
FROM scratch AS export
LABEL droidspaces.name="Alpine Linux v3.23 - XFCE" \
      droidspaces.distro="Alpine" \
      droidspaces.description="Alpine Linux v3.23 rootfs with basic packages, development tools, Docker, and XFCE desktop environment." \
      droidspaces.author="Droidspaces developers"

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /
