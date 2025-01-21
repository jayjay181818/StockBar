# Code Formatting Setup

This project uses automated code formatting to maintain consistent style across all Swift files. Here's how to use it:

## Initial Setup

1. Open Terminal and navigate to the project directory:
   ```bash
   cd /path/to/StockBar
   ```

2. Make the setup script executable:
   ```bash
   chmod +x setup-formatting.sh
   ```

3. Run the setup script:
   ```bash
   ./setup-formatting.sh
   ```

This will:
- Install necessary tools (SwiftLint and swift-format)
- Set up git hooks for automatic formatting
- Create configuration files
- Run initial code formatting

## Usage

### Automatic Formatting

Code will be automatically formatted when you:
- Make a git commit
- Build the project in Xcode

### Manual Formatting

To manually format code:
```bash
./scripts/format.sh
```

### Configuration

The formatting rules are defined in:
- `.swiftlint.yml` - SwiftLint rules
- `scripts/format.sh` - Formatting script

## Rules Enforced

The configuration enforces:
- Line length limits (120 chars warning, 150 chars error)
- No force unwrapping/try
- Consistent spacing and formatting
- Import sorting
- Documentation requirements
- And many other best practices

## IDEs

For the best experience:
- **Xcode**: Install SwiftLint Extension
- **VSCode**: Install Swift extension

## Troubleshooting

If you encounter issues:
1. Make sure tools are installed:
   ```bash
   brew install swiftlint
   brew install swift-format
   ```

2. Try running format manually:
   ```bash
   ./scripts/format.sh
   ```

3. Check SwiftLint output:
   ```bash
   swiftlint
   ```