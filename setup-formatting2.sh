#!/bin/bash

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "Setting up code formatting for StockBar..."

# 1. Create scripts directory if it doesn't exist
mkdir -p scripts

# 2. Create format script
cat > scripts/format.sh << 'EOL'
#!/bin/bash

# Check if swiftlint is installed
if ! command -v swiftlint &> /dev/null; then
    echo "SwiftLint not found. Installing via Homebrew..."
    brew install swiftlint
fi

# Run SwiftLint autocorrect
echo "Running SwiftLint autocorrect..."
swiftlint --fix

# Run final SwiftLint check
echo "Running final SwiftLint check..."
swiftlint

echo "Formatting complete!"
EOL

# 3. Create SwiftLint configuration
cat > .swiftlint.yml << 'EOL'
excluded:
  - Pods
  - .build
  - DerivedData

opt_in_rules:
  - attributes
  - closure_spacing
  - collection_alignment
  - explicit_init
  - explicit_self
  - first_where
  - force_unwrapping
  - operator_usage_whitespace
  - sorted_imports
  - vertical_whitespace_closing_braces

line_length:
  warning: 120
  error: 150

file_length:
  warning: 400
  error: 500

type_body_length:
  warning: 300
  error: 400

function_body_length:
  warning: 50
  error: 80

force_cast: error
force_try: error
force_unwrapping: error

identifier_name:
  min_length: 
    warning: 3
  excluded:
    - id
    - URL
    - x
    - y
    - to

reporter: "xcode"
EOL

# 4. Make scripts executable
chmod +x scripts/format.sh

# 5. Install required tools
echo "Checking and installing required tools..."

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install SwiftLint if not present
if ! command -v swiftlint &> /dev/null; then
    echo "Installing SwiftLint..."
    brew install swiftlint
fi

# 6. Run initial format
echo "Running initial code format..."
./scripts/format.sh

echo -e "${GREEN}Setup complete!${NC}"
echo "The following tools have been set up:"
echo "1. SwiftLint configuration (.swiftlint.yml)"
echo "2. Format script (scripts/format.sh)"
echo ""
echo "You can manually format code at any time by running:"
echo "  ./scripts/format.sh"