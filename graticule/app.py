"""
Application Entry Point for Graticule.
Delegates to the unified CLI / GUI entry point.
"""

import sys
from .cli import main

if __name__ == "__main__":
    sys.exit(main())
