# 🤝 Contributing to Ghost Mode

Thank you for your interest in contributing to **Ghost Mode**! We welcome contributions from developers of all skill levels.

---

## 🛠️ Development Setup

### Prerequisites
- macOS 12.0 (Monterey) or higher
- Xcode Command Line Tools installed (`xcode-select --install`)
- Git

### Getting the Code
```bash
git clone https://github.com/malikarpit/Ghost-Mode.git
cd Ghost-Mode
```

### Building Locally
Ghost Mode uses a `Makefile` for zero-dependency builds:
```bash
# Build the universal app bundle
make

# Build and install directly to /Applications
make install

# Build a release .dmg installer
make dmg
```

---

## 💡 How to Contribute

### 1. Reporting Bugs
- Check the [Issues tab](https://github.com/malikarpit/Ghost-Mode/issues) to ensure your bug hasn't already been reported.
- If it hasn't, open a new issue using our **Bug Report** template.
- Include your macOS version, chip architecture (Apple Silicon / Intel), and clear steps to reproduce.

### 2. Suggesting Enhancements
- Have an idea for a new feature? Open an issue using the **Feature Request** template.
- Explain what problem it solves and how you envision it working.

### 3. Submitting Pull Requests
1. Fork the repository on GitHub.
2. Create a feature branch: `git checkout -b feature/my-new-feature`
3. Commit your changes with clear, descriptive commit messages.
4. Test your build using `make` and `make dmg` to ensure universal compilation passes for both `arm64` and `x86_64`.
5. Push to your branch: `git push origin feature/my-new-feature`
6. Open a Pull Request on GitHub against the `main` branch.

---

## 📝 Code Style & Guidelines
- **Native Swift & AppKit:** We strive to keep Ghost Mode lightweight with zero third-party dependencies.
- **Safety First:** Keep-awake operations must always preserve safety guards (thermal limits, battery cutoff).
- **Universal Binary:** Ensure code compiles cleanly for both `arm64` (Apple Silicon) and `x86_64` (Intel).

---

## 📄 License
By contributing to Ghost Mode, you agree that your contributions will be licensed under the project's [MIT License](LICENSE).
