# conftest.py — repo-level pytest configuration
# Removes ROS2 paths from sys.path before any tests collect, preventing
# the launch_testing pytest plugin from loading (it requires 'lark' which
# is not in this project's venv).
import sys

sys.path = [p for p in sys.path if "/opt/ros" not in p and "launch_testing" not in p]
