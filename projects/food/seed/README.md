# Carga de datos de food

| Archivo                | Contenido                                             |
|------------------------|-------------------------------------------------------|
| `el-corralito.json`    | Restaurante y menú de El Corralito.                   |
| `tags/lote-NNN.json`   | Lotes de etiquetas (estantes). Un lote no se edita después de imprimirlo. |
| `words.txt`            | Palabras para los códigos de etiqueta (323 palabras). |
| `generate-tags.mjs`    | Genera un lote nuevo en stock.                        |
| `import.sh`            | Importa un restaurante o un lote en `neko-supabase`.  |

## Importar

Desde esta carpeta en la VM 200:

```bash
./import.sh restaurant el-corralito.json
./import.sh tags tags/lote-001.json
```

Importar es repetible: el mismo archivo deja los mismos datos. Con otra
conexión: `PSQL="psql -d mi_base" ./import.sh ...`.

Advertencias:

- Importar un restaurante **reemplaza** su menú completo: lo editado en
  Studio para ese restaurante se pierde. Elige una fuente de verdad por
  restaurante: el JSON o Studio.
- Reimportar cambia los identificadores de los platos. Las "Mi lista" abiertas
  en ese momento muestran esos platos como no disponibles.

## Formato del restaurante

```jsonc
{
  "restaurant": {
    "slug": "el-corralito",          // fijo para siempre después de importar
    "name": "El Corralito",
    "tagline": "Múltiple de Sabores",
    "menu_name": "Menú Almuerzos",
    "logo_path": "restaurants/el-corralito/logo.jpg",
    "table_count": 20,
    "latitude": 8.7479,               // sin coordenadas no aparece en el home
    "longitude": -75.8814,
    "show_on_home": true,
    "whatsapp": "+573001234567",
    "tiktok_profile": "usuario",
    "status": "published"             // draft | published | suspended
  },
  "payment": {                        // null si no hay datos de pago
    "breb_key": "@llave",
    "verification_text": "Verifica que el destinatario sea ...",
    "qr_payload": "contenido exacto entregado por la entidad"
  },
  "tiktok_videos": [                  // máximo 3, en orden
    { "url": "https://www.tiktok.com/@usuario/video/1234567890" }
  ],
  "categories": [                     // en orden
    {
      "name": "Bebidas",
      "note": "Texto opcional bajo el título",
      "items": [                      // en orden
        { "name": "Jugos", "description": "Maracuyá o corozo.", "price_cop": 12000 },
        {
          "name": "Agua de panela",
          "variants": [ { "name": "Vaso", "price_cop": 3000 } ],
          "photos": [ "restaurants/el-corralito/panela.jpg" ],
          "is_new": false,
          "is_featured": false,
          "is_visible": true
        }
      ]
    }
  ]
}
```

Los comentarios de este ejemplo no son JSON válido; el archivo real no los
lleva. Una clave desconocida hace fallar la importación con
`FOOD_IMPORT_UNKNOWN_KEY`, para detectar errores de digitación.

Reglas que valida la importación:

- Cada plato tiene `price_cop` o `variants`, nunca ambos ni ninguno.
- Un plato con `is_featured` necesita al menos una foto.
- Máximo 2 fotos por plato y 3 videos por restaurante.
- Videos sólo con la URL completa (`https://www.tiktok.com/@usuario/video/<id>`).

## Fotos

1. En Studio, Storage, bucket `food-assets`, subir la foto en
   `restaurants/<slug>/...`. Máximo 10 MB, JPEG, PNG o WebP, y no más de 16,8
   megapíxeles.
2. Poner esa ruta en `photos` del plato (o en `logo_path`) y reimportar. O, sin
   reimportar, crear la fila en `food.item_photos` desde Studio con el
   `item_id`, la ruta y la posición (1 o 2).

## Estantes

```bash
node generate-tags.mjs 20 lote-002      # crea tags/lote-002.json en stock
./import.sh tags tags/lote-002.json
```

Cada código es de tres palabras (`aspen-muffin-nova`), y la URL que se graba en
el NFC y en el QR es:

```
https://food.nekomotsu.com/s/<código>
```

Para activar un estante en una mesa, sin reimprimir, hay dos formas:

- En Studio, editar su fila en `food.tags`: `status = active`,
  `restaurant_id` y `table_number`.
- O importar un JSON con sus destinos:

```json
[
  { "code": "aspen-muffin-nova", "restaurant_slug": "el-corralito", "table_number": 4 },
  { "code": "barley-prism-ruby", "status": "retired" }
]
```

Con 323 palabras hay unos 33 millones de códigos posibles. Alcanza para food,
cuyas páginas son públicas. Un producto que muestre datos personales al
escanear necesita una lista más grande y límite de frecuencia (estándar 2.9).

## Datos pendientes de El Corralito

`el-corralito.json` no incluye lo que el menú fuente no deja claro. No se
inventaron precios.

| Dato                          | Situación                                                   |
|-------------------------------|-------------------------------------------------------------|
| Asados (pechuga, cerdo, churrasco) | Excluidos. El menú lista 28k y 35k sin decir cuál es de qué plato. |
| Gaseosas, soda y agua         | Excluidas. Precios de 4k, 5k, 6k y 12k sin asignar a productos. |
| `table_count`                 | 20 es un valor provisional. Confirmar la cantidad real.     |
| Coordenadas                   | Vacías. Sin ellas, El Corralito no aparece en el home.      |
| WhatsApp, TikTok, logo, pagos | Vacíos. Pedir al cliente.                                   |
| Fotos                         | Ninguna. Sin fotos no hay platos destacados.                |
| Nombres corregidos            | "Frijoda" quedó como "Frijolada Corralito". Los dos Miti/Miti nuevos quedaron como "Miti-miti de mote de queso" y "Miti-miti de frijoles". Confirmar con el cliente. |
| Frijolada y calderito paisa   | Tienen ingredientes idénticos en el menú fuente. Se copiaron tal cual. |
| Corvina                       | El menú fuente no menciona aguacate, a diferencia de la nota de la categoría. Se copió tal cual. |
