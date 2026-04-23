import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:piczle/main.dart'; // Importando o themeNotifier
import 'dart:isolate';

class _IsolateTask {
  final Uint8List imageBytes;
  final int columns;
  final int rows;
  final String fileName;
  final String format;
  final String targetPath;
  final SendPort sendPort;
  final bool isSingleFile; // Se true, retorna os bytes em vez de salvar

  _IsolateTask({
    required this.imageBytes,
    required this.columns,
    required this.rows,
    required this.fileName,
    required this.format,
    required this.targetPath,
    required this.sendPort,
    this.isSingleFile = false,
  });
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  File? _image;
  int _columns = 3;
  int _rows = 3;
  bool _joinPdf = true;
  bool _zipImages = false;
  bool _isProcessing = false;

  // Novas configurações de exportação
  String _exportFormat = 'PDF'; // 'PDF' ou 'Imagem'
  double _pdfPageWidth = 210; // mm (A4 padrão)
  double _pdfPageHeight = 297; // mm
  double _pdfMarginPercent = 5; // %
  pw.BoxFit _pdfBoxFit = pw.BoxFit.contain;
  String _exportFileName = 'piczle_{n}';

  // Variáveis de controle de progresso
  List<String> _exportLog = [];
  String _currentProcessingFile = "";

  final ImagePicker _picker = ImagePicker();

  /// Seleciona a imagem da galeria
  Future<void> _pickImage() async {
    final XFile? pickedFile = await _picker.pickImage(
      source: ImageSource.gallery,
    );
    if (pickedFile != null) {
      setState(() {
        _image = File(pickedFile.path);
      });
    }
  }

  /// Finaliza a exportação decidindo entre compartilhar (Mobile) ou salvar (Desktop/Linux)
  Future<void> _finishExport({
    required List<String> paths,
    required String fileName,
    required String shareText,
  }) async {
    if (!kIsWeb && Platform.isLinux) {
      if (paths.length == 1) {
        // Para arquivos únicos (PDF ou ZIP), abre o "Salvar como"
        final String? outputFile = await FilePicker.platform.saveFile(
          dialogTitle: 'Salvar Arquivo',
          fileName: fileName,
        );
        if (outputFile == null) return;
        await File(paths.first).copy(outputFile);
        _showStatus('Arquivo salvo com sucesso!');
      } else {
        // Para múltiplas imagens, solicita a pasta de destino
        final String? selectedDirectory = await FilePicker.platform
            .getDirectoryPath();
        if (selectedDirectory == null) return;
        for (var path in paths) {
          final name = path.split('/').last;
          await File(path).copy('$selectedDirectory/$name');
        }
        _showStatus('Imagens salvas em: $selectedDirectory');
      }
    } else {
      // No mobile, mantém o comportamento original de compartilhamento
      await Share.shareXFiles(
        paths.map((path) => XFile(path)).toList(),
        text: shareText,
      );
    }
  }

  void _showStatus(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Processa a imagem e exporta nos formatos desejados
  /// [asPdf] define se o destino é PDF ou Imagens individuais
  /// Se [asPdf] for true, respeita a flag [_joinPdf]
  /// Se [asPdf] for false, respeita a flag [_zipImages]
  Future<void> _exportGrid(bool asPdf) async {
    if (_image == null) return;

    setState(() => _isProcessing = true);
    _exportLog.clear();

    try {
      String? selectedPath;

      // 1. Solicitar local de salvamento
      if (!kIsWeb && Platform.isLinux) {
        selectedPath = await FilePicker.platform.getDirectoryPath(
          dialogTitle: "Selecione a pasta de destino",
        );
      } else {
        String? aDir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: "Selecione a pasta de destino",
        );

        if (aDir == "/") {
          aDir = (await getTemporaryDirectory()).path;
        }

        selectedPath = aDir;
      }

      if (selectedPath == null) {
        setState(() => _isProcessing = false);
        return;
      }

      final bytes = await _image!.readAsBytes();
      final receivePort = ReceivePort();

      // Se for PDF único ou ZIP, ainda precisamos coletar em memória devido às libs
      bool needsCollection =
          (_exportFormat == 'PDF' && _joinPdf) ||
          (_exportFormat == 'Imagem' && _zipImages);

      // 2. Iniciar Isolate para processamento por streaming
      await Isolate.spawn(
        _processStreamingIsolate,
        _IsolateTask(
          imageBytes: bytes,
          columns: _columns,
          rows: _rows,
          fileName: _exportFileName,
          format: _exportFormat,
          targetPath: selectedPath,
          sendPort: receivePort.sendPort,
          isSingleFile: needsCollection,
        ),
      );

      List<Uint8List> collectedBytes = [];

      // 3. Ouvir o progresso do Isolate
      await for (var message in receivePort) {
        if (message is String) {
          if (message == "DONE") break;
          setState(() {
            _currentProcessingFile = message;
            _exportLog.insert(0, "✓ $message");
          });
        } else if (message is Uint8List) {
          collectedBytes.add(message);
        } else if (message is Map && message.containsKey('error')) {
          throw Exception(message['error']);
        }
      }
      receivePort.close();

      // 4. Lógica de finalização para arquivos agrupados
      if (needsCollection) {
        _showStatus("Agrupando arquivos...");
        if (_exportFormat == 'PDF') {
          await _saveJoinedPdf(collectedBytes, selectedPath);
        } else {
          await _saveZipFile(collectedBytes, selectedPath);
        }
      } else if (!Platform.isLinux) {
        // No Mobile, se não for Linux, após salvar tudo localmente, oferecemos o compartilhamento
        // O log já contém os caminhos.
      }

      _showStatus("Exportação concluída!");
    } catch (e) {
      debugPrint("Erro ao exportar: $e");
      _showStatus("Erro: $e");
    } finally {
      setState(() {
        _isProcessing = false;
        _currentProcessingFile = "";
      });
    }
  }

  Future<void> _saveJoinedPdf(List<Uint8List> result, String path) async {
    final pdf = pw.Document();
    final margin =
        (_pdfPageWidth < _pdfPageHeight ? _pdfPageWidth : _pdfPageHeight) *
        (_pdfMarginPercent / 100);

    for (var tileBytes in result) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(
            _pdfPageWidth * PdfPageFormat.mm,
            _pdfPageHeight * PdfPageFormat.mm,
          ),
          build: (context) => pw.Padding(
            padding: pw.EdgeInsets.all(margin * PdfPageFormat.mm),
            child: pw.Center(
              child: pw.Image(pw.MemoryImage(tileBytes), fit: _pdfBoxFit),
            ),
          ),
        ),
      );
    }
    final file = File(
      '$path/$_exportFileName.pdf'.replaceAll('{n}', 'completo'),
    );
    await file.writeAsBytes(await pdf.save());
  }

  Future<void> _saveZipFile(List<Uint8List> result, String path) async {
    final archive = Archive();
    for (int i = 0; i < result.length; i++) {
      final name = _exportFileName.replaceAll('{n}', (i + 1).toString());
      archive.addFile(ArchiveFile('$name.jpg', result[i].length, result[i]));
    }
    final zip = ZipEncoder().encode(archive);
    if (zip != null) await File('$path/export.zip').writeAsBytes(zip);
  }

  static Future<void> _processStreamingIsolate(_IsolateTask task) async {
    try {
      final img.Image? fullImage = img.decodeImage(task.imageBytes);
      if (fullImage == null) throw "Erro ao decodificar imagem";

      final int tileWidth = (fullImage.width / task.columns).floor();
      final int tileHeight = (fullImage.height / task.rows).floor();
      int count = 1;

      for (int y = 0; y < task.rows; y++) {
        for (int x = 0; x < task.columns; x++) {
          final img.Image tile = img.copyCrop(
            fullImage,
            x: x * tileWidth,
            y: y * tileHeight,
            width: tileWidth,
            height: tileHeight,
          );
          final tileBytes = Uint8List.fromList(img.encodeJpg(tile));
          final name = task.fileName.replaceAll('{n}', count.toString());

          if (task.isSingleFile) {
            task.sendPort.send(tileBytes);
          } else {
            final ext = task.format == 'PDF' ? 'pdf' : 'jpg';
            final file = File('${task.targetPath}/$name.$ext');
            if (task.format == 'PDF') {
              final pdf = pw.Document();
              pdf.addPage(
                pw.Page(
                  build: (c) =>
                      pw.Center(child: pw.Image(pw.MemoryImage(tileBytes))),
                ),
              );
              file.writeAsBytesSync(await pdf.save());
            } else {
              file.writeAsBytesSync(tileBytes);
            }
          }
          task.sendPort.send("$name processado");
          count++;
        }
      }
      task.sendPort.send("DONE");
    } catch (e) {
      task.sendPort.send({'error': e.toString()});
    }
  }

  void _showExportDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 24,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Text("Configurar Exportação"),
              content: SizedBox(
                width: MediaQuery.of(context).size.width * 0.9,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'Nome base do arquivo',
                          helperText: 'Use {n} para numeração (ex: foto_{n})',
                          border: OutlineInputBorder(),
                        ),
                        controller: TextEditingController(
                          text: _exportFileName,
                        ),
                        onChanged: (val) {
                          _exportFileName = val;
                        },
                      ),
                      const SizedBox(height: 16),
                      _buildExportTypeSelector(
                        onChanged: (val) {
                          setDialogState(() => _exportFormat = val!);
                        },
                      ),
                      const Divider(),
                      if (_exportFormat == 'PDF') ...[
                        _buildPdfPreview(),
                        const SizedBox(height: 16),
                        SwitchListTile(
                          title: const Text("Unir único PDF"),
                          value: _joinPdf,
                          onChanged: (val) =>
                              setDialogState(() => _joinPdf = val),
                        ),
                        _buildSlider(
                          "Largura (mm)",
                          _pdfPageWidth.toInt(),
                          50,
                          500,
                          (val) {
                            setDialogState(() => _pdfPageWidth = val);
                          },
                        ),
                        _buildSlider(
                          "Altura (mm)",
                          _pdfPageHeight.toInt(),
                          50,
                          500,
                          (val) {
                            setDialogState(() => _pdfPageHeight = val);
                          },
                        ),
                        _buildSlider(
                          "Margem (%)",
                          _pdfMarginPercent.toInt(),
                          0,
                          25,
                          (val) {
                            setDialogState(() => _pdfMarginPercent = val);
                          },
                        ),
                        ListTile(
                          title: const Text("Ajuste"),
                          trailing: DropdownButton<pw.BoxFit>(
                            value: _pdfBoxFit,
                            onChanged: (val) =>
                                setDialogState(() => _pdfBoxFit = val!),
                            items: const [
                              DropdownMenuItem(
                                value: pw.BoxFit.contain,
                                child: Text("Conter"),
                              ),
                              DropdownMenuItem(
                                value: pw.BoxFit.cover,
                                child: Text("Cobrir"),
                              ),
                              DropdownMenuItem(
                                value: pw.BoxFit.fill,
                                child: Text("Preencher"),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        const Icon(
                          Icons.insert_photo,
                          size: 64,
                          color: Colors.blue,
                        ),
                        SwitchListTile(
                          title: const Text("Unir em ZIP"),
                          value: _zipImages,
                          onChanged: (val) =>
                              setDialogState(() => _zipImages = val),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cancelar"),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _exportGrid(_exportFormat == 'PDF');
                  },
                  icon: const Icon(Icons.check),
                  label: const Text("Confirmar"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildPdfPreview() {
    return Column(
      children: [
        const Text(
          "Pré-visualização da Página",
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        Container(
          height: 200,
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: AspectRatio(
              aspectRatio: _pdfPageWidth / _pdfPageHeight,
              child: Container(
                margin: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
                ),
                child: Padding(
                  padding: EdgeInsets.all(
                    _pdfMarginPercent,
                  ), // Simula a margem em %
                  child: Container(
                    color: Colors.blue.withOpacity(0.1),
                    child: Stack(
                      children: [
                        if (_image != null)
                          Positioned.fill(
                            child: Opacity(
                              opacity: 0.6,
                              child: FittedBox(
                                fit: _getBoxFit(_pdfBoxFit),
                                child: ClipRect(
                                  child: Align(
                                    alignment: Alignment.topLeft,
                                    widthFactor: 1 / _columns,
                                    heightFactor: 1 / _rows,
                                    child: Image.file(_image!),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        const Center(
                          child: Icon(Icons.crop_free, color: Colors.blue),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Text(
          "${_pdfPageWidth.toInt()}mm x ${_pdfPageHeight.toInt()}mm",
          style: const TextStyle(fontSize: 10),
        ),
      ],
    );
  }

  BoxFit _getBoxFit(pw.BoxFit fit) {
    switch (fit) {
      case pw.BoxFit.contain:
        return BoxFit.contain;
      case pw.BoxFit.cover:
        return BoxFit.cover;
      case pw.BoxFit.fill:
        return BoxFit.fill;
      default:
        return BoxFit.contain;
    }
  }

  IconData _getThemeIcon(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return Icons.light_mode;
      case ThemeMode.dark:
        return Icons.dark_mode;
      case ThemeMode.system:
        return Icons.brightness_auto;
    }
  }

  void _toggleTheme() {
    if (themeNotifier.value == ThemeMode.system) {
      themeNotifier.value = ThemeMode.light;
    } else if (themeNotifier.value == ThemeMode.light) {
      themeNotifier.value = ThemeMode.dark;
    } else {
      themeNotifier.value = ThemeMode.system;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PicZle Grid'),
        leading: _image != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _image = null),
                tooltip: "Voltar e descartar",
              )
            : null,
        actions: [
          IconButton(
            icon: Icon(_getThemeIcon(themeNotifier.value)),
            onPressed: () => setState(() => _toggleTheme()),
            tooltip: "Alternar Tema",
          ),
          if (_image != null)
            TextButton.icon(
              label: const Text("Exportar"),
              icon: const Icon(Icons.send_rounded),
              onPressed: _isProcessing ? null : _showExportDialog,
            ),
        ],
      ),
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: _image == null
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.image_search,
                                size: 80,
                                color: Colors.grey,
                              ),
                              const SizedBox(height: 16),
                              ElevatedButton.icon(
                                onPressed: _pickImage,
                                icon: const Icon(Icons.add_photo_alternate),
                                label: const Text('Selecionar Imagem'),
                              ),
                            ],
                          )
                        : Stack(
                            children: [
                              Image.file(_image!),
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: GridPainter(
                                    columns: _columns,
                                    rows: _rows,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
                if (_image != null)
                  Card(
                    margin: const EdgeInsets.all(16),
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          _buildSectionTitle("Configuração da Grade"),
                          _buildSlider("Colunas (W)", _columns, 1, 10, (val) {
                            setState(() => _columns = val.toInt());
                          }),
                          _buildSlider("Linhas (H)", _rows, 1, 10, (val) {
                            setState(() => _rows = val.toInt());
                          }),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_isProcessing)
            Container(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 16),
                    const Text(
                      "Processando imagem...",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      _currentProcessingFile,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      height: 200,
                      width: 300,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: _exportLog.length,
                        itemBuilder: (context, index) {
                          return Text(
                            _exportLog[index],
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          color: Colors.blueGrey,
        ),
      ),
    );
  }

  Widget _buildExportTypeSelector({ValueChanged<String?>? onChanged}) {
    return ListTile(
      title: const Text("Tipo de Exportação"),
      trailing: DropdownButton<String>(
        value: _exportFormat,
        onChanged: (val) {
          setState(() => _exportFormat = val!);
          if (onChanged != null) onChanged(val);
        },
        items: <String>['PDF', 'Imagem'].map<DropdownMenuItem<String>>((
          String value,
        ) {
          return DropdownMenuItem<String>(value: value, child: Text(value));
        }).toList(),
      ),
    );
  }

  Widget _buildSlider(
    String label,
    int value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Row(
      children: [
        Expanded(flex: 2, child: Text(label)),
        Expanded(
          flex: 5,
          child: Slider(
            value: value.toDouble(),
            min: min,
            max: max,
            divisions: (max - min).toInt(),
            label: value.toString(),
            onChanged: onChanged,
          ),
        ),
        Text(value.toString()),
      ],
    );
  }
}

class GridPainter extends CustomPainter {
  final int columns;
  final int rows;

  GridPainter({required this.columns, required this.rows});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final shadowPaint = Paint()
      ..color = Colors.black45
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;

    for (int i = 1; i < columns; i++) {
      double dx = (size.width / columns) * i;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), shadowPaint);
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), paint);
    }

    for (int i = 1; i < rows; i++) {
      double dy = (size.height / rows) * i;
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), shadowPaint);
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), paint);
    }
  }

  @override
  bool shouldRepaint(covariant GridPainter oldDelegate) =>
      oldDelegate.columns != columns || oldDelegate.rows != rows;
}
