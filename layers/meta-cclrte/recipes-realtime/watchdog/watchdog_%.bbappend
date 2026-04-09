# CCLRTE watchdog configuration is provided via watchdog-config_%.bbappend
# The upstream watchdog recipe removes watchdog.conf from its own package
# (see poky/meta/recipes-extended/watchdog/watchdog_5.16.bb) and delegates
# it to the separate watchdog-config recipe. We override it there instead.
