# Third-party notices

MacToys is an independent project. It is inspired by, and reimplements the features of,
[Microsoft PowerToys](https://github.com/microsoft/PowerToys) for macOS. It is not affiliated with,
endorsed by or sponsored by Microsoft. "PowerToys" is a trademark of Microsoft Corporation.

## Microsoft PowerToys (MIT License)

Parts of MacToys are derived from PowerToys source code:

| MacToys file | Derived from |
|---|---|
| `Sources/Modules/QuickAccent/AccentSets.swift` | Quick Accent character sets, `CharacterMappings.cs` (generated) |
| `Sources/Modules/ColorPicker/ColorNames.swift` | Color Picker `ColorNameHelper` (ported) |
| `Sources/Modules/ColorPicker/ColorMath.swift` | Color Picker `ColorFormatHelper` conversions (ported, so formats print the same values) |

```
MIT License

Copyright (c) Microsoft Corporation. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE
```

## Data and algorithms used at runtime

- **Homebrew command-not-found index** — Command Not Found downloads `executables.txt`, published by
  the Homebrew project (BSD 2-Clause License), on demand. It is not bundled.
- **NOAA solar calculator** — Light Switch computes sunrise and sunset with the public-domain
  algorithm published by the NOAA Global Monitoring Laboratory.
- **SF Symbols** — icons are drawn with Apple's SF Symbols through the system frameworks and are
  subject to Apple's terms; they are not redistributed as files.
