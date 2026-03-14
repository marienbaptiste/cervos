# Contributing

Thank you for your interest in contributing to Cervos!

## Getting Started

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Follow the [Setup Guide](setup-guide.md) to get your development environment running
4. Make your changes
5. Run tests (`./scripts/test-e2e.sh`)
6. Submit a pull request

## Code Style

- **Flutter/Dart**: Follow the [Effective Dart](https://dart.dev/guides/language/effective-dart) guidelines
- **Python**: Follow PEP 8
- **C (firmware)**: Follow the Zephyr coding style
- **YAML configs**: 2-space indentation

## Design System

All UI changes must conform to the design system. Run `design-lint` before submitting:

```bash
cd design-system/tools
./design-lint ../
```

## Architecture Decisions

Major architectural changes should be discussed in an issue first. See [architecture.md](architecture.md) for the current system design.
