// Turns the logos in manifest.json into BrandIcons.json path data for the app bundles, refusing licences that cannot ship.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const modules = join(here, 'node_modules');

const listInputs = process.argv[2] === '--inputs';
const output = listInputs ? null : process.argv[2]
  ?? (process.env.TARGET_BUILD_DIR && process.env.UNLOCALIZED_RESOURCES_FOLDER_PATH
    ? join(process.env.TARGET_BUILD_DIR, process.env.UNLOCALIZED_RESOURCES_FOLDER_PATH, 'BrandIcons')
    : null);
if (!output && !listInputs) fail('usage: node build.mjs <output directory> | --inputs');

const simpleRoot = join(modules, 'simple-icons');
const lobeRoot = join(modules, '@lobehub', 'icons-static-svg');
if (!existsSync(simpleRoot) || !existsSync(lobeRoot)) {
  fail(`icon packages are not installed; run "npm ci" in ${here}`);
}

const manifest = JSON.parse(readFileSync(join(here, 'manifest.json'), 'utf8'));
const inputList = join(here, 'inputs.xcfilelist');
const inputs = [
  join(simpleRoot, 'package.json'), join(simpleRoot, 'sdk.mjs'), join(simpleRoot, 'data', 'simple-icons.json'), join(lobeRoot, 'package.json'),
  ...Object.values(manifest['simple-icons']).map((slug) => join(simpleRoot, 'icons', `${slug}.svg`)),
  ...Object.values(manifest.lobe).map((slug) => join(lobeRoot, 'icons', `${slug}.svg`)),
].map((file) => file.replace(here, '$(SRCROOT)/Icons')).join('\n') + '\n';

// Xcode's script sandbox only lets the build phase touch the files it declares, so npm ci records them.
if (listInputs) {
  writeFileSync(inputList, inputs);
  process.exit(0);
}
if (!existsSync(inputList) || readFileSync(inputList, 'utf8') !== inputs) {
  fail(`inputs.xcfilelist is out of date with manifest.json; run "npm ci" in ${here}`);
}

// Creative Commons, GPL and non-commercial terms are refused: CC forbids the DRM the App Store applies.
const shippable = new Set(['CC0-1.0', 'MIT', 'Apache-2.0', 'BSD-2-Clause', 'BSD-3-Clause']);
const { getIconSlug } = await import(join(simpleRoot, 'sdk.mjs'));
const simpleData = JSON.parse(readFileSync(join(simpleRoot, 'data', 'simple-icons.json'), 'utf8'));
const simpleEntries = new Map((Array.isArray(simpleData) ? simpleData : simpleData.icons).map((icon) => [getIconSlug(icon), icon]));
const packageInfo = (root) => JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
const version = (root) => packageInfo(root).version;
const packageLicense = (root) => {
  const { name, license } = packageInfo(root);
  if (!shippable.has(license)) fail(`${name} declares ${license ?? 'no licence'}, which cannot ship in the app`);
  return license;
};
const simpleLicense = packageLicense(simpleRoot);
const lobeLicense = packageLicense(lobeRoot);

mkdirSync(output, { recursive: true });
const credits = [];
const glyphs = {};

for (const [key, slug] of Object.entries(manifest['simple-icons'])) {
  const entry = simpleEntries.get(slug);
  if (!entry) fail(`simple-icons has no icon "${slug}" (for "${key}")`);
  const license = entry.license ? entry.license.type : simpleLicense;
  if (!shippable.has(license)) fail(`simple-icons "${slug}" is ${license ?? 'under unrecognised terms'}, which cannot ship in the app`);
  glyphs[key] = glyph(join(simpleRoot, 'icons', `${slug}.svg`));
  if (license !== simpleLicense) credits.push({ title: entry.title, license, url: entry.license?.url, source: entry.source });
}

for (const [key, slug] of Object.entries(manifest.lobe)) {
  glyphs[key] = glyph(join(lobeRoot, 'icons', `${slug}.svg`));
}

const creditedLicenses = [...new Set(credits.map((credit) => credit.license))].sort();
const notices = [
  'Brand icons',
  '',
  'All logos are trademarks of their respective owners and are shown only to identify the program or project type they belong to.',
  '',
  `Simple Icons ${version(simpleRoot)} (https://simpleicons.org), ${simpleLicense}.`,
  ...(credits.length ? [
    '',
    'These icons from that set carry their own licence, whose text follows the list:',
    ...credits.map(({ title, license, url, source }) => `  ${title}: ${license}${url ? `, ${url}` : ''}, source ${source}`),
  ] : []),
  ...creditedLicenses.flatMap((license) => [
    '',
    `${license} licence text, applying to the icons above that carry it:`,
    '',
    standardText(license),
  ]),
  '',
  `Lobe Icons, @lobehub/icons-static-svg ${version(lobeRoot)} (https://github.com/lobehub/lobe-icons), ${lobeLicense}:`,
  '',
  readFileSync(join(here, 'LICENSE-lobe-icons.txt'), 'utf8').trim(),
  '',
].join('\n');
writeFileSync(join(output, 'BrandIcons.json'), JSON.stringify(glyphs));
writeFileSync(join(output, 'NOTICES.txt'), notices);

function glyph(source) {
  if (!existsSync(source)) fail(`missing ${source}`);
  const svg = readFileSync(source, 'utf8');
  const root = svg.match(/<svg\b[^>]*>/)?.[0] ?? '';
  const viewBox = root.match(/viewBox="([^"]+)"/)?.[1].trim().split(/[\s,]+/).map(Number);
  if (viewBox?.length !== 4 || viewBox.some(Number.isNaN)) fail(`${source} has no usable viewBox`);
  const unsupported = svg.match(/<(?!svg\b|\/|title\b|path\b|\?xml)[a-zA-Z]+/)?.[0] ?? svg.match(/\s(transform|clip-path|mask)=/)?.[1];
  if (unsupported) fail(`${source} uses ${unsupported}, which BrandIcons.json cannot carry`);
  const evenOdd = /fill-rule="evenodd"/.test(root);
  const paths = [...svg.matchAll(/<path\b[^>]*>/g)].map(([tag]) => tag.match(/\sd="([^"]+)"/)?.[1]).filter(Boolean);
  if (paths.length === 0) fail(`${source} has no path data`);
  return { viewBox, evenOdd, paths };
}

function fail(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}

function standardText(license) {
  const holders = 'Copyright (c) the respective owners of the icons credited above';
  const text = {
    'MIT': `${holders}

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
SOFTWARE.`,
    'BSD-2-Clause': `${holders}

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.`,
    'BSD-3-Clause': `${holders}

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.`,
    'Apache-2.0': `                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.`,
  }[license];
  if (!text) fail(`no licence text is bundled for ${license}`);
  return text;
}
