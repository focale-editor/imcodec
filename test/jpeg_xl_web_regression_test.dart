import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Checks real libjxl output on VM, JavaScript and Dart WebAssembly runtimes.
void main() {
  test('libjxl modular output decodes without native-only typed lists', () {
    final Image decoded = decodeJpegXl(base64Decode(_fixture));
    final Uint8List expected = Uint8List(17 * 9 * 4);
    for (int y = 0; y < 9; y++) {
      for (int x = 0; x < 17; x++) {
        expected.setRange((y * 17 + x) * 4, (y * 17 + x + 1) * 4, [
          (x * 13 + y * 7) % 256,
          (y * 27 + 33) % 256,
          (x * 7 + y * 19) % 256,
          [0, 1, 64, 128, 254, 255][(x + y) % 6],
        ]);
      }
    }
    expect((decoded.width, decoded.height), (17, 9));
    expect(decoded.bytes, expected);
  });
}

/// Original synthetic RGBA data encoded with libjxl 0.12.0, lossless effort 1.
const String _fixture =
    '/wpAACCAlQgIEADpAUsYm5xxhAM4gAM4IErAOQUBACBEgAgQASJAhP/37/nvoTHnnGvtc2+SJAkBVVVVVVXV////c+/r7u7uhv+Xe/6/h8aac6251t5JkiQE'
    'VFVVVVVV////z72vu7u7G/7fv+e/h8acc661z71JkiQEVFVVVVVV////z72vu7u7G/7fv+e/h8acc661z71JkiQEVFVVVVVV////z72vu7u7+wKiCXBBLvjy'
    'x82F2r3kgjwOzlFehLNe/Gtz0R57F/6CPFYeRI/XB8jg7ivcXajuQl2zC3XNLtQ1u1DX7EJdswfXNbtmD65rdqGu2YW6Zheqe2R1F+qarTz2hbpmp354XLML'
    'dc2Ocs0eEtfsQl2z+WNfs4fBNYsPq2t2xEfFES/9NbtQ1+y4j46jXu5Hz0Nm8zU7yvEeEcc78DW72NfsWEd6FBzp8NfsAl+zh8U1u/TX7Mpfzmv2QLxmx71m'
    'l3v+ml2zB9/ma3Y5r9nluGaX85pdjmt25R6I1+xyXLPLec0uxzW7nNfscoxejmt22a7N5eiYO9SjYdU1ezhcoZOd7EG09bBnPf7FOetD/Lqe43JdyyOc+Bo8'
    'HHYd4cxrr+5hr+Zhr8VFOcll3frAuMqHfYBco8Of8PJtfQBsPcKpjnA1LslZ91/dw669zoe9Ske/rgc/48XbevkfI/sv3YIHyCPv9Id9DD1gH0PnukibL/Mj'
    'b3i8SEd5JBz2uh7ieJfo0XDY3Rf50XAZLs2FfQxdhoM8QB6vhz3XpTjYWS/kmS7mI++wE4+awz4UFj4SDnvND3tdLsQVO+6pLuUFv0IXbOuD4ayXfOsD5KwP'
    'kK2c9pL5hdm6lq47/nU6yGnKI+y7QnOD5xg505JH+IVfeyUuyBU67PJ9O6eX25F3HGvz8nMtP/Xy63HcHdfjgPuXn2752ZdPb5lefsK5RUfesfXS7DrGSZaf'
    '6fDnXH4VmkUnPt71CMfbeEGuIAc4z/LTHvnKVCumOdTuo6w9+8zB9h7o3MvSGTeuPtXK63F5dhznBFdg5Zkv0vkuwI4Vh99xPS7DEbcdeMchznKk7etOemHi'
    '2dZdh5UnX3c9Vl6PdfX6Ez06H6zrjLM+bmD3uTkr14NrwOODHVz3s3I9uK6c2+Z2z+1mN7vZzW7OB+djN7vZPXd8WHKJzr+by3d+dnMJllwLdvMgvvZLrh0P'
    '3EcfF+B6XYDHA7u5AA/La//4eYA++i7AiofTtX9QXvuH1pKrzwPr2j/4rv2DacnV58Gx5NrzILMlV58HwZJrf/mXLLn6F3+JLdESW6IldnGWaIkt0RJbItOS'
    'BygirBHZGG/dICZyLLpxkWZsVHwrsh1r7xUcOx7euGNscOQKNnYs3N4uPDYsvHG16ODoJczdQ+Lt5aKDQxewV44OD17D3HaVlcz1woKjlzC3jQ+PX8Lef40V'
    'hu4bGh69hLlq3ALRi5iLr7JI+IWjw+OXsE/BMiuEr2HuH7/ICgsssED4GuYJWGiR8CXkCVlvnQUWSFgleg3zDCyyyAoLmCdiwYWWiHa3Bg==';
