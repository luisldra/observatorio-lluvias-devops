// Pipeline multibranch: develop -> DEV, qa -> QA, main -> PDN.
// Frontend: Firebase Hosting (un target por ambiente). API: Render (un servicio por ambiente).
// BD: Neon PostgreSQL (una rama por ambiente, configurada solo en Render).
// Secretos en Jenkins Credentials (ver docs/DESPLIEGUE.md):
//   firebase-service-account  (Secret file)  cuenta de servicio con rol "Firebase Hosting Admin"
//   render-deploy-hook-dev    (Secret text)  Deploy Hook del servicio Render DEV
//   render-deploy-hook-qa     (Secret text)  Deploy Hook del servicio Render QA
//   render-deploy-hook-prod   (Secret text)  Deploy Hook del servicio Render PDN

def deployTo(String envName) {
  withCredentials([
    string(credentialsId: "render-deploy-hook-${envName}", variable: 'RENDER_DEPLOY_HOOK'),
    file(credentialsId: 'firebase-service-account', variable: 'GOOGLE_APPLICATION_CREDENTIALS')
  ]) {
    sh "./scripts/deploy.sh ${envName}"
  }
  sh "./scripts/smoke-test.sh ${envName}"
}

pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timeout(time: 60, unit: 'MINUTES')
  }

  stages {
    stage('Instalar dependencias') {
      steps {
        sh 'chmod +x scripts/*.sh'
        dir('frontend') { sh 'npm ci' }
        dir('backend') { sh 'mvn -B -q dependency:resolve' }
      }
    }

    stage('Análisis básico') {
      steps {
        dir('frontend') { sh 'npm audit --omit=dev --audit-level=critical' }
        dir('backend') { sh 'mvn -B -q validate' }
      }
    }

    stage('Pruebas automatizadas') {
      parallel {
        stage('Frontend (Vitest)') {
          steps { dir('frontend') { sh 'npm test' } }
        }
        stage('Backend (JUnit)') {
          steps { dir('backend') { sh 'mvn -B test' } }
          post { always { junit allowEmptyResults: true, testResults: 'backend/target/surefire-reports/*.xml' } }
        }
      }
    }

    stage('Empaquetado') {
      steps {
        dir('backend') { sh 'mvn -B -DskipTests package' }
        // Build genérico para verificar que compila; cada ambiente recompila con su VITE_API_URL al desplegar.
        dir('frontend') { sh 'npm run build' }
      }
    }

    stage('Deploy DEV') {
      when { branch 'develop' }
      steps { script { deployTo('dev') } }
    }

    stage('Deploy QA') {
      when { branch 'qa' }
      steps {
        script { deployTo('qa') }
        sh './scripts/acceptance-test.sh qa'
      }
    }

    stage('Aprobación PDN') {
      when { branch 'main' }
      steps {
        timeout(time: 30, unit: 'MINUTES') {
          input message: '¿Autorizar despliegue a PDN/producción?', ok: 'Desplegar a PDN'
        }
      }
    }

    stage('Deploy PDN') {
      when { branch 'main' }
      steps { script { deployTo('prod') } }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'frontend/dist/**,backend/target/*.jar', allowEmptyArchive: true
    }
    success {
      echo "OK: rama ${env.BRANCH_NAME}, commit ${env.GIT_COMMIT}, build #${env.BUILD_NUMBER}"
    }
    failure {
      echo "FALLÓ: rama ${env.BRANCH_NAME}, build #${env.BUILD_NUMBER}. No se promovió ningún cambio."
    }
  }
}
