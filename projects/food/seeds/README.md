# Seeds de food

Se aplican en cada deploy de `neko-supabase` cuando son nuevos o cuando
cambia su `.sql` o su `.json`. Este README se ignora en el deploy.

## Rangos de numeración

| Rango   | Contenido                   | Función                  |
|---------|-----------------------------|--------------------------|
| 100-199 | Un restaurante por archivo. | `food.import_restaurant` |
| 200-299 | Un lote de estantes en stock por archivo (lote N = 200 + N). | `food.import_tags` |
| 300-399 | Estantes activos y retirados. | `food.import_tags`     |

El orden importa: los restaurantes se cargan antes que los estantes que
apuntan a ellos.

| Archivo                     | Contenido                                        |
|-----------------------------|--------------------------------------------------|
| `100_el_corralito`          | Restaurante y menú de El Corralito.              |
| `201_tags_lote_001`         | 20 estantes en stock. No se edita después de imprimirlo. |
| `300_estantes_activos`      | Vacío. Aquí se activan los estantes instalados.  |

## Cambiar un menú

Editar el JSON del restaurante, correr `./projects/run-tests.sh food`, push y
deploy. El seed reemplaza el menú completo de ese restaurante.

Consecuencias:

- Lo editado en Studio para ese restaurante se pierde.
- Los identificadores de los platos cambian: las "Mi lista" abiertas en ese
  momento muestran esos platos como no disponibles.
- El slug no se cambia nunca después del primer deploy.

## Agregar un restaurante

Copiar `100_el_corralito.sql` y `.json` como `101_<nombre>` y editar el JSON.

Formato del JSON (los comentarios son sólo explicativos; el archivo real no
los lleva):

```jsonc
{
  "restaurant": {
    "slug": "el-corralito",          // fijo para siempre después del primer deploy
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

El deploy falla si:

- Hay una clave desconocida (`FOOD_IMPORT_UNKNOWN_KEY`), para detectar errores
  de digitación.
- Un plato tiene `price_cop` y `variants` a la vez, o ninguno de los dos
  (`FOOD_IMPORT_PRICE_OR_VARIANTS`).
- Un plato con `is_featured` no tiene fotos (`FOOD_IMPORT_FEATURED_WITHOUT_PHOTO`).
- Un plato tiene más de 2 fotos, el restaurante más de 3 videos, o un video no
  usa la URL completa (`https://www.tiktok.com/@usuario/video/<id>`).
- Se viola cualquier otra restricción de la base de datos.

## Fotos

Las fotos son archivos, no datos, así que se suben en Studio (Storage, bucket
`food-assets`) en `restaurants/<slug>/...`: máximo 10 MB, JPEG, PNG o WebP, y
no más de 16,8 megapíxeles. Después se pone la ruta en `photos` o en
`logo_path` y se despliega.

## Estantes

Lote nuevo, desde `projects/food`:

```bash
node tools/generate-tags.mjs 20 2     # crea seeds/202_tags_lote_002.json y .sql
```

Cada código es de tres palabras (`aspen-muffin-nova`). La URL que se graba en
el NFC y en el QR es `https://food.nekomotsu.com/s/<código>`.

Activar, mover o retirar estantes: editar `300_estantes_activos.json`.

```json
[
  { "code": "aspen-muffin-nova", "restaurant_slug": "el-corralito", "table_number": 4 },
  { "code": "barley-prism-ruby", "status": "retired" }
]
```

- Quitar una entrada de este archivo **no** desactiva el estante. Para
  sacarlo de servicio se deja con `"status": "retired"`.
- Un estante retirado no se reactiva: el deploy falla con `FOOD_TAG_RETIRED`.
- Con 323 palabras hay unos 33 millones de códigos. Alcanza para food, cuyas
  páginas son públicas.

## Datos pendientes de El Corralito

El JSON no incluye lo que el menú fuente no deja claro. No se inventaron
precios.

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
