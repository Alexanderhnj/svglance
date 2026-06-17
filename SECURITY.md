# Security Policy

## Supported Versions

Security fixes are intended for the latest released version of SVGlance.

## Reporting a Vulnerability

Please do not file public issues for sensitive security reports.

Until a dedicated security email is configured, contact the maintainer privately through the GitHub profile connected to the SVGlance repository. Include:

- a short summary of the issue
- steps to reproduce
- affected macOS version
- affected SVGlance version
- whether the issue involves a crafted SVG file, folder permission handling, or app distribution

## Security Model

SVGlance is sandboxed and uses user-approved folder access. SVG scripts are stripped before rendering in SVGlance-controlled previews. JavaScript is disabled for WebKit-based rendering where applicable.
