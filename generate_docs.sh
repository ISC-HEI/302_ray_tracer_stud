#!/bin/bash
# Script to generate Doxygen documentation for CS302 Ray Tracer

echo "Generating documentation with Doxygen..."
doxygen Doxyfile

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Documentation generated successfully!"
    echo "  HTML docs: docs/html/index.html"
    echo "  LaTeX docs: docs/latex/"
    echo ""
    echo "To view the HTML documentation, run:"
    echo "  xdg-open docs/html/index.html"
else
    echo "✗ Documentation generation failed!"
    exit 1
fi
