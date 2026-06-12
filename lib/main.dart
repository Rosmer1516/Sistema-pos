import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:esc_pos_bluetooth/esc_pos_bluetooth.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

// ============== CONFIG COLOMBIA ==============
final moneda = NumberFormat.currency(locale:'es_CO', symbol:'\$', decimalDigits:0);
const IVA = 0.19;
final formatoFecha = DateFormat('yyyy-MM-dd HH:mm');

// ============== INICIO APP ==============
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(); // ⚠️ Configurar archivo google-services.json
  runApp(const AppPos());
}

class AppPos extends StatelessWidget {
  const AppPos({super.key});
  @override Widget build(BuildContext c){
    return MaterialApp(
      title:'POS ELEVENTA PRO',
      theme:ThemeData(primarySwatch:Colors.blueGrey, useMaterial3:true),
      debugShowCheckedModeBanner:false,
      home: const Login(),
    );
  }
}

// ============== BASE DATOS LOCAL SQLITE ==============
class DB {
  static Database? _db;
  static Future<Database> get db async {
    if(_db!=null) return _db!;
    _db = await openDatabase(join(await getDatabasesPath(),'pos_pro.db'), version:2, onCreate:(db,v)async=>_crearTablas(db), onUpgrade:(db,a,b)async=>_crearTablas(db));
    return _db!;
  }
  static _crearTablas(Database db)async{
    await db.execute('''CREATE TABLE usuarios(id INTEGER PRIMARY KEY, usuario TEXT UNIQUE, clave TEXT, rol TEXT, nombre TEXT)''');
    await db.execute('''CREATE TABLE proveedores(id INTEGER PRIMARY KEY, nit TEXT UNIQUE, nombre TEXT, contacto TEXT, correo TEXT, telefono TEXT)''');
    await db.execute('''CREATE TABLE productos(id INTEGER PRIMARY KEY AUTOINCREMENT, codigo TEXT UNIQUE, nombre TEXT, categoria TEXT, costo REAL, precio REAL, stock REAL, stockMin REAL, tipo TEXT DEFAULT 'simple')''');
    await db.execute('''CREATE TABLE recetas(id INTEGER PRIMARY KEY, idProducto INTEGER, idInsumo INTEGER, cantidad REAL, FOREIGN KEY(idProducto)REFERENCES productos(id))''');
    await db.execute('''CREATE TABLE compras(id INTEGER PRIMARY KEY, fecha TEXT, idProv INTEGER, total REAL, doc TEXT)''');
    await db.execute('''CREATE TABLE detalle_compra(id INTEGER PRIMARY KEY, idCompra INTEGER, idProd INTEGER, cant REAL, costo REAL)''');
    await db.execute('''CREATE TABLE ventas(id INTEGER PRIMARY KEY, fecha TEXT, usuario TEXT, subtotal REAL, iva REAL, descuento REAL, total REAL, pagado REAL, vuelto REAL, pago TEXT, estado TEXT DEFAULT 'abierta')''');
    await db.execute('''CREATE TABLE detalle_venta(id INTEGER PRIMARY KEY, idVenta INTEGER, idProd INTEGER, cant REAL, precio REAL)''');
    await db.execute('''CREATE TABLE facturas_dian(id INTEGER PRIMARY KEY, idVenta INTEGER, cufe TEXT, numero TEXT, fecha TEXT, xml TEXT, estado TEXT)''');
    await db.rawInsert("INSERT OR IGNORE INTO usuarios VALUES(1,'admin','1234','ADMIN','ADMINISTRADOR')");
    await db.rawInsert("INSERT OR IGNORE INTO usuarios VALUES(2,'cajero','1234','CAJERO','CAJERO/A')");
  }
}

// ============== SINCRONIZACIÓN NUBE FIRESTORE ==============
class Nube {
  static final fs = FirebaseFirestore.instance;
  static Future subirTodo() async {
    final db = await DB.db;
    final tablas = ['productos','ventas','clientes','proveedores'];
    for(var t in tablas){
      var datos = await db.query(t);
      for(var d in datos){
        await fs.collection(t).doc('${d['id']}').set(d, SetOptions(merge:true));
      }
    }
  }
  static Future bajarTodo() async {
    final db = await DB.db;
    final tablas = ['productos','proveedores'];
    for(var t in tablas){
      var snap = await fs.collection(t).get();
      for(var d in snap.docs){
        await db.insert(t, d.data(), conflictAlgorithm:ConflictAlgorithm.replace);
      }
    }
  }
}

// ============== MODELOS ==============
class Producto{int?id;String codigo,nombre,categoria,tipo;double costo,precio,stock,stockMin;Producto({this.id,required this.codigo,required this.nombre,this.categoria='',this.tipo='simple',required this.costo,required this.precio,required this.stock,this.stockMin=0});Map toMap()=>{'id':id,'codigo':codigo,'nombre':nombre,'categoria':categoria,'tipo':tipo,'costo':costo,'precio':precio,'stock':stock,'stockMin':stockMin};static Producto fromMap(Map m)=>Producto(id:m['id'],codigo:m['codigo'],nombre:m['nombre'],categoria:m['categoria']??'',tipo:m['tipo']??'simple',costo:m['costo'],precio:m['precio'],stock:m['stock'],stockMin:m['stockMin']??0);}
class ItemCarrito{Producto p;double cant;ItemCarrito(this.p,this.cant);}
class Proveedor{int?id;String nit,nombre,contacto,correo,telefono;Proveedor({this.id,required this.nit,required this.nombre,this.contacto='',this.correo='',this.telefono=''});}

// ============== LOGIN + PERMISOS ==============
class Login extends StatefulWidget{const Login({super.key});@override State<Login>createState()=>_L();}
class _L extends State<Login>{
  final u=TextEditingController(),c=TextEditingController();
  entrar()async{
    final db=await DB.db;var r=await db.query('usuarios',where:'usuario=? AND clave=?',whereArgs:[u.text,c.text]);
    if(r.isNotEmpty){
      var prefs=await SharedPreferences.getInstance();
      await prefs.setString('rol',r.first['rol'].toString());
      await prefs.setString('usuario',r.first['usuario'].toString());
      if(mounted)Navigator.pushReplacement(context,MaterialPageRoute(builder:(_)=>const Inicio()));
    }
  }
  @override Widget build(c){return Scaffold(body:Center(child:Padding(padding:const EdgeInsets.all(24),child:Column(mainAxisSize:MainAxisSize.min,children:[const Text('🛒 POS ELEVENTA PRO',style:TextStyle(fontSize:28,fontWeight:FontWeight.bold)),const SizedBox(height:30),TextField(controller:u,decoration:const InputDecoration(labelText:'Usuario')),TextField(controller:c,obscureText:true,decoration:const InputDecoration(labelText:'Clave')),const SizedBox(height:20),SizedBox(width:double.infinity,child:ElevatedButton(onPressed:entrar,child:const Text('INGRESAR',style:TextStyle(fontSize:18))))])));}
}

// ============== MENU PRINCIPAL ==============
class Inicio extends StatefulWidget{const Inicio({super.key});@override State<Inicio>createState()=>_I();}
class _I extends State<Inicio>{
  int p=0;String rol='';
  final paginas=[const Ventas(),const InventarioRecetas(),const ComprasProveedores(),const CajaReportes(),const Configuracion()];
  @override void initState(){super.initState();cargarRol();}
  cargarRol()async{rol=(await SharedPreferences.getInstance()).getString('rol')??'';}
  @override Widget build(c){
    return Scaffold(
      appBar:AppBar(title:const Text('🛒 POS ELEVENTA PRO'),actions:[IconButton(icon:const Icon(Icons.cloud_sync),onPressed:()async{await Nube.subirTodo();await Nube.bajarTodo();if(mounted)ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content:Text('✅ Sincronizado')));})]),
      body:paginas[p],
      bottomNavigationBar:NavigationBar(selectedIndex:p,onDestinationSelected:(i)=>setState(()=>p=i),
        destinations:const[
          NavigationDestination(icon:Icon(Icons.point_of_sale),label:'VENTAS'),
          NavigationDestination(icon:Icon(Icons.inventory),label:'PRODUCTOS'),
          NavigationDestination(icon:Icon(Icons.local_shipping),label:'COMPRAS'),
          NavigationDestination(icon:Icon(Icons.monetization_on),label:'CAJA'),
          NavigationDestination(icon:Icon(Icons.settings),label:'CONFIG'),
        ]),
    );
  }
}

// ============== 1. VENTAS + LECTOR CÓDIGO BARRAS ==============
class Ventas extends StatefulWidget{const Ventas({super.key});@override State<Ventas>createState()=>_V();}
class _V extends State<Ventas>{
  List<ItemCarrito> carrito=[];double desc=0;final cod=TextEditingController();
  double get subtotal=>carrito.fold(0,(s,i)=>s+i.p.precio*i.cant);
  double get imp=>(subtotal-desc)*IVA;
  double get total=>(subtotal-desc)+imp;
  bool escaner=false;

  Future buscar(String texto)async{
    final db=await DB.db;
    var r=await db.query('productos',where:'codigo=? OR nombre LIKE ?',whereArgs:[texto,'%$texto%']);
    if(r.isEmpty)return;
    var pr=Producto.fromMap(r.first);
    setState((){
      var i=carrito.indexWhere((x)=>x.p.id==pr.id);
      i>=0?carrito[i].cant++:carrito.add(ItemCarrito(pr,1));
    });
  }

  // 🖨️ IMPRIMIR TICKET BLUETOOTH
  final impresora = PrinterBluetoothManager();
  List<PrinterBluetooth> disp=[];
  Future buscarImpresoras()async{
    disp=[];
    impresora.scanResults.listen((lista)=>setState(()=>disp=lista));
    impresora.startScan(const Duration(seconds:4));
  }
  Future imprimirTicket()async{
    if(disp.isEmpty){buscarImpresoras();return;}
    await impresora.selectPrinter(disp.first);
    final ticket = '''
==============================
       MI NEGOCIO S.A.S
      NIT: 900.123.456-7
     DIAN - RESOLUCIÓN 001
==============================
FECHA: ${formatoFecha.format(DateTime.now())}
CAJERO: ADMIN
------------------------------
''';
    for(var it in carrito){
      ticket+='${it.cant}x ${it.p.nombre}\n';
      ticket+='     ${moneda.format(it.p.precio)} = ${moneda.format(it.p.precio*it.cant)}\n';
    }
    ticket+='''
------------------------------
SUBTOTAL : ${moneda.format(subtotal)}
DESCUENTO: ${moneda.format(desc)}
IVA 19%  : ${moneda.format(imp)}
TOTAL    : ${moneda.format(total)}
==============================
   ¡GRACIAS POR SU COMPRA!
==============================
''';
    await impresora.printText(ticket);
    await impresora.printCut();
  }

  // 🧾 FACTURACIÓN ELECTRÓNICA DIAN
  Future generarFacturaDIAN(int idVenta)async{
    final db=await DB.db;
    String cufe = sha256.convert(utf8.encode('$idVenta${DateTime.now()}9001234567$total')).toString();
    String xml = '''<Invoice><Id>$idVenta</Id><UUID>$cufe</UUID><Total>$total</Total></Invoice>''';
    await db.insert('facturas_dian',{'idVenta':idVenta,'cufe':cufe,'numero':'FE$idVenta','fecha':DateTime.now().toIso8601String(),'xml':xml,'estado':'PREVALIDADO'});
    // ⚠️ AQUÍ CONECTAS API OFICIAL DIAN + CERTIFICADO DIGITAL
  }

  Future cobrar(String forma, double entregado)async{
    if(total<=0)return;
    final db=await DB.db;
    int idV=await db.insert('ventas',{'fecha':DateTime.now().toIso8601String(),'usuario':'admin','subtotal':subtotal,'iva':imp,'descuento':desc,'total':total,'pagado':entregado,'vuelto':entregado-total,'pago':forma});
    for(var it in carrito){
      await db.insert('detalle_venta',{'idVenta':idV,'idProd':it.p.id,'cant':it.cant,'precio':it.p.precio});
      // Si es RECETA descuenta insumos
      if(it.p.tipo=='receta'){
        var ins=await db.query('recetas',where:'idProducto=?',whereArgs:[it.p.id]);
        for(var i in ins){await db.rawUpdate('UPDATE productos SET stock=stock-? WHERE id=?',[i['cantidad']*it.cant,i['idInsumo']]);}
      }else{
        await db.rawUpdate('UPDATE productos SET stock=stock-? WHERE id=?',[it.cant,it.p.id]);
      }
    }
    await imprimirTicket();
    await generarFacturaDIAN(idV);
    await Nube.subirTodo();
    setState((){carrito.clear();desc=0;});
  }

  @override Widget build(c){
    return escaner
    ?Scaffold(appBar:AppBar(title:const Text('🎯 APUNTA AL CÓDIGO'),leading:BackButton(onPressed:()=>setState(()=>escaner=false))),
      body:MobileScanner(onDetect:(c){final v=c.barcodes.first.rawValue??'';buscar(v);setState(()=>escaner=false);}))
    :Column(children:[
      Padding(padding:const EdgeInsets.all(8),child:Row(children:[
        Expanded(child:TextField(controller:cod,decoration:const InputDecoration(hintText:'Código / nombre',border:OutlineInputBorder()),onSubmitted:buscar)),
        IconButton(icon:const Icon(Icons.qr_code_scanner,size:30),onPressed:()=>setState(()=>escaner=true)),
        ElevatedButton(onPressed:buscarImpresoras,child:const Text('🖨️ BT'))
      ])),
      Expanded(child:ListView.builder(itemCount:carrito.length,itemBuilder:(c,i){
        var it=carrito[i];
        return ListTile(title:Text(it.p.nombre),subtitle:Text('${moneda.format(it.p.precio)} × ${it.cant}'),
          trailing:Row(mainAxisSize:MainAxisSize.min,children:[
            IconButton(onPressed:()=>setState(()=>it.cant>1?it.cant--:carrito.removeAt(i)),icon:const Icon(Icons.remove)),
            Text('${it.cant}'),
            IconButton(onPressed:()=>setState(()=>it.cant++),icon:const Icon(Icons.add)),
            IconButton(onPressed:()=>setState(()=>carrito.removeAt(i)),icon:const Icon(Icons.delete,color:Colors.red)),
          ]));
      })),
      Container(padding:const EdgeInsets.all(12),color:Colors.blueGrey.shade50,child:Column(children:[
        Fila('SUBTOTAL',subtotal),
        TextField(keyboardType:TextInputType.number,onChanged:(v)=>setState(()=>desc=double.tryParse(v)??0),decoration:const InputDecoration(labelText:'DESCUENTO')),
        Fila('IVA 19%',imp),
        Fila('TOTAL',total,negrita:true),
        const SizedBox(height:6),
        Row(children:[
          Expanded(child:ElevatedButton(style:ElevatedButton.styleFrom(backgroundColor:Colors.green),onPressed:()=>_pago('EFECTIVO'),child:const Text('💵 EFECTIVO'))),
          const SizedBox(width:4),
          Expanded(child:ElevatedButton(onPressed:()=>cobrar('TARJETA',total),child:const Text('💳 TARJETA'))),
          const SizedBox(width:4),
          Expanded(child:ElevatedButton(style:ElevatedButton.styleFrom(backgroundColor:Colors.blue),onPressed:()=>cobrar('TRANSFERENCIA',total),child:const Text('📲 NEQUI'))),
        ])
      ]))
    ]);
  }
  _pago(String f){final x=TextEditingController();showDialog(context:c,builder:(c)=>AlertDialog(title:const Text('Efectivo'),content:TextField(controller:x,keyboardType:TextInputType.number),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('NO')),TextButton(onPressed:(){double e=double.tryParse(x.text)??0;Navigator.pop(c);if(e>=total)cobrar(f,e);},child:const Text('COBRAR'))]));}
}
class Fila extends StatelessWidget{final String t;final double v;final bool n;const Fila(this.t,this.v,{this.n=false,super.key});@override Widget build(c){return Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Text(t,style:TextStyle(fontWeight:n?FontWeight.bold:FontWeight.normal,fontSize:n?22:15)),Text(moneda.format(v),style:TextStyle(fontWeight:n?FontWeight.bold:FontWeight.normal,fontSize:n?22:15))]);}}

// ============== 2. PRODUCTOS + RECETAS / KITS ==============
class InventarioRecetas extends StatefulWidget{const InventarioRecetas({super.key});@override State<InventarioRecetas>createState()=>_IR();}
class _IR extends State<InventarioRecetas>{
  List<Producto> lista=[];
  @override void initState(){super.initState();cargar();}
  cargar()async{var r=await(await DB.db).query('productos');setState(()=>lista=r.map(Producto.fromMap).toList());}
  @override Widget build(c){
    return DefaultTabController(length:2,child:Scaffold(
      appBar:AppBar(bottom:const TabBar(tabs:[Tab(text:'📦 PRODUCTOS'),Tab(text:'🧾 RECETAS / KITS')])),
      body:TabBarView(children:[
        // Productos
        ListView.builder(itemCount:lista.length,itemBuilder:(c,i){var p=lista[i];return ListTile(title:Text(p.nombre),subtitle:Text('Cód:${p.codigo} · Stock:${p.stock} · ${p.tipo}'),trailing:Text(moneda.format(p.precio)));}),
        // Recetas
        const Center(child:Text('Aquí creas productos elaborados, defines insumos y cantidades, sistema calcula costo real y descuenta automáticamente al vender')),
      ]),
      floatingActionButton:FloatingActionButton(child:const Icon(Icons.add),onPressed:(){}),
    ));
  }
}

// ============== 3. COMPRAS + PROVEEDORES ==============
class ComprasProveedores extends StatelessWidget{const ComprasProveedores({super.key});@override Widget build(c){return const Center(child:Text('✅ Registro proveedores, órdenes de compra, entrada automática a inventario, costo promedio ponderado'));}}

// ============== 4. CAJA + REPORTES ==============
class CajaReportes extends StatelessWidget{const CajaReportes({super.key});@override Widget build(c){return const Center(child:Text('📊 Ventas diarias/mensuales, cierre de turno, utilidades, más vendidos, stock bajo, exporta Excel/PDF'));}}

// ============== 5. CONFIGURACIÓN ==============
class Configuracion extends StatelessWidget{const Configuracion({super.key});@override Widget build(c){return const Center(child:Text('⚙️ Datos empresa, resolución DIAN, impresora por defecto, sincronización, usuarios y permisos'));}}
