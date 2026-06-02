# Fix pseudo lchown() EINVAL on zoneinfo symlinks (absolute-path symlinks
# confuse pseudo's lchown interception on Ubuntu 24.04 / kernel 6.x).
# Override chown as a shell function so the recursive chown in do_install
# never exits non-zero.
do_install:prepend() {
    chown() { command chown "$@" 2>/dev/null || true; }
}
