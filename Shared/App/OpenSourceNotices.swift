/// Licences of the open-source code Aeolet ships, shown under Settings on iPhone, iPad and Mac.
enum OpenSourceNotices {
    static let text = """
    Aeolet is licensed under the Apache License 2.0.

    OpenPGP.js is licensed under the GNU Lesser General Public License v3.0 or later. Source: github.com/openpgpjs/openpgpjs. You may replace the bundled library by rebuilding from PGP/js in this project's source code.

    SwiftMail (IMAP and SMTP), github.com/Cocoanetics/SwiftMail, is licensed under the BSD 2-Clause License:

    """ + swiftMailLicense + """


    SwiftMail uses SwiftNIO, swift-nio-ssl, swift-nio-imap, swift-log, swift-collections, swift-atomics and swift-system (Apache License 2.0) and SwiftCross (MIT License).
    """

    private static let swiftMailLicense = "Copyright (c) 2025, Oliver Drobnik All rights reserved.\n\nRedistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:\n\n- Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.\n\n- Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.\n\nTHIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \"AS IS\" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE."
}
